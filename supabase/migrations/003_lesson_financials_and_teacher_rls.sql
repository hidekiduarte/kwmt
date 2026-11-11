-- KWMT migration 003: aula vinculada a preço/pacote, repasse automático e RLS refinado
-- Aplicar somente depois de revisar e testar as migrations 001 e 002.
-- Esta migration é aditiva; não executa alterações no projeto Supabase até ser aplicada.

-- 1) Vincular cada aula ao tipo comercial e, quando aplicável, ao pacote consumido.
alter table public.lessons
  add column if not exists lesson_type_id uuid,
  add column if not exists student_package_id uuid;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'lessons_school_lesson_type_fk'
      and conrelid = 'public.lessons'::regclass
  ) then
    alter table public.lessons
      add constraint lessons_school_lesson_type_fk
      foreign key (school_id, lesson_type_id)
      references public.lesson_types(school_id, id);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'lessons_school_student_package_fk'
      and conrelid = 'public.lessons'::regclass
  ) then
    alter table public.lessons
      add constraint lessons_school_student_package_fk
      foreign key (school_id, student_package_id)
      references public.student_packages(school_id, id);
  end if;
end;
$$;

create index if not exists idx_lessons_school_lesson_type
  on public.lessons(school_id, lesson_type_id);
create index if not exists idx_lessons_school_student_package
  on public.lessons(school_id, student_package_id);

-- 2) Controle de créditos consumidos. O bloqueio da linha do pacote na função
-- financeira evita consumo concorrente do mesmo crédito.
alter table public.student_packages
  add column if not exists lessons_used integer not null default 0;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'student_packages_lessons_used_valid'
      and conrelid = 'public.student_packages'::regclass
  ) then
    alter table public.student_packages
      add constraint student_packages_lessons_used_valid
      check (lessons_used >= 0 and lessons_used <= lessons_purchased);
  end if;
end;
$$;

-- 3) Professor só lê a própria linha quando continua ativo na escola.
drop policy if exists "teachers owner or self read" on public.teachers;
drop policy if exists "teachers owner or active assigned teacher read" on public.teachers;
create policy "teachers owner or active assigned teacher read"
on public.teachers
for select to authenticated
using (
  public.is_school_owner(school_id)
  or public.is_assigned_teacher(id)
);

-- 3A) O pacote deve estar ativo também no momento de vincular uma aula agendada.
-- O lock serializa a alocação com cancelamentos e outras operações do pacote.
create or replace function public.validate_scheduled_lesson_package()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_package_status text;
  v_package_expires_at timestamptz;
  v_package_student_id uuid;
begin
  if new.status <> 'scheduled' or new.student_package_id is null then
    return new;
  end if;

  select sp.status, sp.expires_at, sp.student_id
    into v_package_status, v_package_expires_at, v_package_student_id
  from public.student_packages sp
  where sp.school_id = new.school_id
    and sp.id = new.student_package_id
  for update;

  if not found then
    raise exception 'Student package not found for this school';
  end if;

  if v_package_student_id is distinct from new.student_id then
    raise exception 'Student package does not belong to the lesson student';
  end if;

  if v_package_status is distinct from 'active' then
    raise exception 'Cannot schedule a lesson with a cancelled, expired or completed package';
  end if;

  if v_package_expires_at is not null and v_package_expires_at <= now() then
    raise exception 'Cannot schedule a lesson with an expired package';
  end if;

  return new;
end;
$$;

revoke all on function public.validate_scheduled_lesson_package() from public, anon, authenticated;
drop trigger if exists trg_validate_scheduled_lesson_package on public.lessons;
create trigger trg_validate_scheduled_lesson_package
before insert or update of school_id, student_id, student_package_id, status, starts_at, ends_at on public.lessons
for each row execute function public.validate_scheduled_lesson_package();

-- 3B) Estados terminais não podem voltar a active; completed exige todos os créditos.
create or replace function public.validate_student_package_lifecycle()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.lessons_used <> 0 then
      raise exception 'A new package must start with zero lessons used';
    end if;
    if new.status <> 'active' then
      raise exception 'A new package must start active';
    end if;
    if new.expires_at is not null and new.expires_at <= now() then
      raise exception 'A new package cannot be created with an expired validity date';
    end if;
    return new;
  end if;

  if old.status in ('completed','expired','cancelled')
     and new.status is distinct from old.status then
    raise exception 'A terminal package status cannot be reactivated or changed';
  end if;

  if new.status = 'completed'
     and new.lessons_used <> new.lessons_purchased then
    raise exception 'A package can only be completed after all lessons are consumed';
  end if;

  if new.lessons_used < old.lessons_used then
    raise exception 'Consumed package credits cannot be restored by editing the counter';
  end if;

  if new.lessons_used > new.lessons_purchased then
    raise exception 'Consumed lessons cannot exceed purchased lessons';
  end if;

  return new;
end;
$$;

revoke all on function public.validate_student_package_lifecycle() from public, anon, authenticated;
drop trigger if exists trg_validate_student_package_lifecycle on public.student_packages;
create trigger trg_validate_student_package_lifecycle
before insert or update of status, lessons_used on public.student_packages
for each row execute function public.validate_student_package_lifecycle();

-- 3C) Impede cancelar pacote enquanto houver aula futura/em andamento agendada.
-- O proprietário deve cancelar ou reagendar explicitamente cada aula antes.
create or replace function public.prevent_package_cancel_with_scheduled_lessons()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_scheduled_count integer;
begin
  if old.status is distinct from 'cancelled'
     and new.status = 'cancelled' then
    select count(*)::integer
      into v_scheduled_count
    from public.lessons l
    where l.school_id = new.school_id
      and l.student_package_id = new.id
      and l.status = 'scheduled'
      and l.ends_at > now();

    if v_scheduled_count > 0 then
      raise exception
        'Cannot cancel package: % future or ongoing scheduled lesson(s) must be cancelled or rescheduled first',
        v_scheduled_count;
    end if;
  end if;

  return new;
end;
$$;

revoke all on function public.prevent_package_cancel_with_scheduled_lessons() from public, anon, authenticated;
drop trigger if exists trg_prevent_package_cancel_with_scheduled_lessons on public.student_packages;
create trigger trg_prevent_package_cancel_with_scheduled_lessons
before update of status on public.student_packages
for each row execute function public.prevent_package_cancel_with_scheduled_lessons();

-- 3D) Reduzir/definir validade não pode deixar aulas agendadas além do vencimento.
-- Estender expires_at é permitido; reduzir exige resolver antes as aulas incompatíveis.
create or replace function public.prevent_package_expiry_before_scheduled_lessons()
returns trigger
language plpgsql
security definer
set search_path = ''
as $
declare
  v_conflicting_count integer;
begin
  if new.expires_at is distinct from old.expires_at
     and new.expires_at is not null then
    select count(*)::integer
      into v_conflicting_count
    from public.lessons l
    where l.school_id = new.school_id
      and l.student_package_id = new.id
      and l.status = 'scheduled'
      and l.ends_at > new.expires_at;

    if v_conflicting_count > 0 then
      raise exception
        'Cannot shorten package validity: % scheduled lesson(s) end after the new expiration date',
        v_conflicting_count;
    end if;
  end if;

  return new;
end;
$;

revoke all on function public.prevent_package_expiry_before_scheduled_lessons() from public, anon, authenticated;
drop trigger if exists trg_prevent_package_expiry_before_scheduled_lessons on public.student_packages;
create trigger trg_prevent_package_expiry_before_scheduled_lessons
before update of expires_at on public.student_packages
for each row execute function public.prevent_package_expiry_before_scheduled_lessons();

-- 4) Ao concluir, validar presença e gerar a fotografia financeira uma única vez.
-- Pacotes reconhecem o valor contratado proporcional por crédito, independentemente
-- do valor já recebido. O caixa recebido será controlado separadamente na migration 004.
create or replace function public.record_lesson_financials()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_gross numeric(10,2);
  v_payout numeric(10,2);
  v_package_price numeric(10,2);
  v_lessons_purchased integer;
  v_lessons_used integer;
  v_package_status text;
  v_package_expires_at timestamptz;
  v_package_student_id uuid;
  v_lesson_price numeric(10,2);
begin
  if new.status <> 'completed' or old.status = 'completed' then
    return new;
  end if;

  if old.status = 'cancelled' then
    raise exception 'Cancelled lessons cannot be completed';
  end if;

  if new.attendance_confirmed_at is null
     or new.attendance_confirmed_by is null then
    raise exception 'Lesson completion requires confirmed attendance';
  end if;

  -- Se já existe fotografia financeira, não consome outro crédito.
  if exists (
    select 1
    from public.lesson_financial_records r
    where r.school_id = new.school_id
      and r.lesson_id = new.id
  ) then
    return new;
  end if;

  if new.student_package_id is not null then
    select sp.contracted_amount, sp.lessons_purchased, sp.lessons_used,
           sp.status, sp.expires_at, sp.student_id
      into v_package_price, v_lessons_purchased, v_lessons_used,
           v_package_status, v_package_expires_at, v_package_student_id
    from public.student_packages sp
    where sp.school_id = new.school_id
      and sp.id = new.student_package_id
    for update;

    if not found then
      raise exception 'Student package not found for this school';
    end if;

    if v_package_student_id <> new.student_id then
      raise exception 'Student package does not belong to the lesson student';
    end if;

    if v_package_status <> 'active'
       or (v_package_expires_at is not null and v_package_expires_at <= now()) then
      raise exception 'Student package is not active or has expired';
    end if;

    if v_package_expires_at is not null and new.ends_at > v_package_expires_at then
      raise exception 'Lesson must end on or before the student package expiration date';
    end if;

    if v_lessons_used >= v_lessons_purchased then
      raise exception 'Student package has no remaining lessons';
    end if;

    v_gross := round(v_package_price / v_lessons_purchased, 2);

    -- Ajusta os centavos restantes no último crédito.
    if v_lessons_used + 1 = v_lessons_purchased then
      v_gross := v_package_price
        - (round(v_package_price / v_lessons_purchased, 2) * (v_lessons_purchased - 1));
    end if;

    update public.student_packages
    set lessons_used = lessons_used + 1,
        status = case
          when lessons_used + 1 >= lessons_purchased then 'completed'
          else status
        end
    where school_id = new.school_id
      and id = new.student_package_id;
  else
    if new.lesson_type_id is null then
      raise exception 'A lesson type is required for a non-package lesson';
    end if;

    select lt.price
      into v_lesson_price
    from public.lesson_types lt
    where lt.school_id = new.school_id
      and lt.id = new.lesson_type_id
      and lt.active = true;

    if not found then
      raise exception 'Active lesson type not found for this school';
    end if;

    v_gross := v_lesson_price;
  end if;

  select pr.payout_amount
    into v_payout
  from public.teacher_payout_rules pr
  where pr.school_id = new.school_id
    and pr.teacher_id = new.teacher_id
    and (pr.lesson_type_id = new.lesson_type_id or pr.lesson_type_id is null)
  order by (pr.lesson_type_id is not null) desc
  limit 1;

  if not found then
    raise exception 'No payout rule configured for this teacher';
  end if;

  insert into public.lesson_financial_records (
    school_id, lesson_id, lesson_type_id, student_package_id,
    gross_amount, teacher_payout_amount
  )
  values (
    new.school_id, new.id, new.lesson_type_id, new.student_package_id,
    v_gross, v_payout
  )
  on conflict (school_id, lesson_id) do nothing;

  return new;
end;
$$;

drop trigger if exists trg_record_lesson_financials on public.lessons;
create trigger trg_record_lesson_financials
after update of status on public.lessons
for each row
when (old.status is distinct from 'completed' and new.status = 'completed')
execute function public.record_lesson_financials();

-- A função é executada pelo trigger; clientes não podem invocá-la diretamente.
revoke all on function public.record_lesson_financials() from public, anon, authenticated;

-- A RPC confirm_lesson_attendance() da migration 001 já grava os dois campos
-- de confirmação e só aceita aulas scheduled cujo horário terminou.
