-- KWMT migration 004: caixa append-only, reembolsos, anulacoes e limite de divida.
-- Pre-requisito: migrations 001, 002 e 003 revisadas.
-- contracted_amount = valor acordado; receipts/refunds/voids = movimentacoes reais de caixa.

-- 1) Limite maximo de saldo devedor permitido para consumir creditos.
-- Zero exige quitacao. A interface deve explicar que pagamento parcial exige configuracao.
alter table public.schools
  add column if not exists package_debt_limit numeric(10,2) not null default 0
  check (package_debt_limit >= 0);

comment on column public.schools.package_debt_limit is
  'Saldo devedor maximo permitido por pacote para consumir creditos. Zero exige quitacao.';

-- 2) Recebimentos sao eventos imutaveis. Anulacoes e reembolsos ficam em tabelas proprias.
create table if not exists public.package_receipts (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.schools(id) on delete restrict,
  student_package_id uuid not null,
  amount numeric(10,2) not null check (amount > 0),
  payment_method text not null
    check (payment_method in ('cash','pix','credit_card','debit_card','bank_transfer','other')),
  received_at timestamptz not null default now(),
  reference text,
  notes text,
  received_by uuid not null default auth.uid() references auth.users(id),
  created_at timestamptz not null default now(),
  foreign key (school_id, student_package_id)
    references public.student_packages(school_id, id) on delete restrict,
  unique (school_id, id, student_package_id)
);

create index if not exists idx_package_receipts_package_date
  on public.package_receipts(school_id, student_package_id, received_at);

alter table public.package_receipts enable row level security;
drop policy if exists "owners manage package receipts" on public.package_receipts;
drop policy if exists "owners read package receipts" on public.package_receipts;
drop policy if exists "owners record package receipts" on public.package_receipts;
create policy "owners read package receipts"
on public.package_receipts for select to authenticated
using (public.is_school_owner(school_id));
create policy "owners record package receipts"
on public.package_receipts for insert to authenticated
with check (public.is_school_owner(school_id));

revoke all on public.package_receipts from anon, authenticated;
grant select, insert on public.package_receipts to authenticated;

-- Defesa em profundidade: mesmo que privilegios sejam alterados no futuro,
-- UPDATE/DELETE de recebimentos continuam proibidos.
create or replace function public.reject_package_receipt_mutation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise exception 'Package receipts are immutable; record a refund or void event instead';
end;
$$;

drop trigger if exists trg_package_receipts_immutable on public.package_receipts;
create trigger trg_package_receipts_immutable
before update or delete on public.package_receipts
for each row execute function public.reject_package_receipt_mutation();
revoke all on function public.reject_package_receipt_mutation() from public, anon, authenticated;

-- A autoria e definida no banco; valores enviados pelo cliente sao ignorados.
create or replace function public.set_package_cash_event_actor()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $
begin
  if tg_table_name = 'package_receipts' then
    new.received_by := auth.uid();
  else
    new.recorded_by := auth.uid();
  end if;
  if auth.uid() is null then
    raise exception 'Authentication required to record package cash events';
  end if;
  return new;
end;
$;
revoke all on function public.set_package_cash_event_actor() from public, anon, authenticated;
create trigger trg_set_package_receipt_actor
before insert on public.package_receipts
for each row execute function public.set_package_cash_event_actor();

-- 3) Anulacao e reembolso sao eventos append-only distintos.
create table if not exists public.package_receipt_voids (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.schools(id) on delete restrict,
  student_package_id uuid not null,
  package_receipt_id uuid not null,
  reason text not null,
  voided_at timestamptz not null default now(),
  recorded_by uuid not null default auth.uid() references auth.users(id),
  created_at timestamptz not null default now(),
  foreign key (school_id, package_receipt_id, student_package_id)
    references public.package_receipts(school_id, id, student_package_id) on delete restrict,
  unique (school_id, package_receipt_id)
);

create table if not exists public.package_receipt_refunds (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.schools(id) on delete restrict,
  student_package_id uuid not null,
  package_receipt_id uuid not null,
  amount numeric(10,2) not null check (amount > 0),
  payment_method text not null
    check (payment_method in ('cash','pix','credit_card','debit_card','bank_transfer','other')),
  refunded_at timestamptz not null default now(),
  reason text not null,
  recorded_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  foreign key (school_id, package_receipt_id, student_package_id)
    references public.package_receipts(school_id, id, student_package_id) on delete restrict
);

create index if not exists idx_package_receipt_voids_package
  on public.package_receipt_voids(school_id, student_package_id);
create trigger trg_set_package_receipt_void_actor
before insert on public.package_receipt_voids
for each row execute function public.set_package_cash_event_actor();
create trigger trg_set_package_receipt_refund_actor
before insert on public.package_receipt_refunds
for each row execute function public.set_package_cash_event_actor();

create index if not exists idx_package_receipt_refunds_receipt_date
  on public.package_receipt_refunds(school_id, package_receipt_id, refunded_at);

alter table public.package_receipt_voids enable row level security;
alter table public.package_receipt_refunds enable row level security;

drop policy if exists "owners read package receipt voids" on public.package_receipt_voids;
create policy "owners read package receipt voids"
on public.package_receipt_voids for select to authenticated
using (public.is_school_owner(school_id));
drop policy if exists "owners record package receipt voids" on public.package_receipt_voids;
create policy "owners record package receipt voids"
on public.package_receipt_voids for insert to authenticated
with check (public.is_school_owner(school_id));

drop policy if exists "owners read package receipt refunds" on public.package_receipt_refunds;
create policy "owners read package receipt refunds"
on public.package_receipt_refunds for select to authenticated
using (public.is_school_owner(school_id));
drop policy if exists "owners record package receipt refunds" on public.package_receipt_refunds;
create policy "owners record package receipt refunds"
on public.package_receipt_refunds for insert to authenticated
with check (public.is_school_owner(school_id));

revoke all on public.package_receipt_voids, public.package_receipt_refunds from anon, authenticated;
grant select, insert on public.package_receipt_voids, public.package_receipt_refunds to authenticated;
-- Nenhuma permissao UPDATE/DELETE: eventos de caixa sao append-only.

-- 4) Fonte unica da verdade para saldo devedor. SECURITY INVOKER faz a funcao
-- respeitar RLS do chamador; os gatilhos SECURITY DEFINER tambem a utilizam
-- depois de adquirir o lock do pacote.
create or replace function public.package_outstanding_amount(
  target_school_id uuid,
  target_student_package_id uuid
)
returns numeric(10,2)
language sql
volatile
security invoker
set search_path = ''
as $$
  select greatest(
    sp.contracted_amount - coalesce((
      select sum(pr.amount - coalesce(refunds.refunded_amount, 0))
      from public.package_receipts pr
      left join (
        select package_receipt_id, sum(amount) as refunded_amount
        from public.package_receipt_refunds
        where school_id = target_school_id
        group by package_receipt_id
      ) refunds on refunds.package_receipt_id = pr.id
      where pr.school_id = target_school_id
        and pr.student_package_id = target_student_package_id
        and not exists (
          select 1
          from public.package_receipt_voids pv
          where pv.school_id = pr.school_id
            and pv.package_receipt_id = pr.id
        )
    ), 0),
    0
  )::numeric(10,2)
  from public.student_packages sp
  where sp.school_id = target_school_id
    and sp.id = target_student_package_id;
$$;

revoke all on function public.package_outstanding_amount(uuid, uuid) from public, anon;
grant execute on function public.package_outstanding_amount(uuid, uuid) to authenticated;

-- 5) Todos os caminhos de escrita adquirem primeiro o mesmo lock da linha do pacote.
-- Recebimentos concorrentes sao serializados antes de calcular o saldo existente.
create or replace function public.validate_package_receipt_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_contracted_amount numeric(10,2);
  v_outstanding numeric(10,2);
begin
  select sp.contracted_amount
    into v_contracted_amount
  from public.student_packages sp
  where sp.school_id = new.school_id
    and sp.id = new.student_package_id
  for update;

  if not found then
    raise exception 'Student package not found for receipt';
  end if;

  v_outstanding := public.package_outstanding_amount(new.school_id, new.student_package_id);

  if (v_contracted_amount - v_outstanding) + new.amount > v_contracted_amount then
    raise exception 'Net package receipts cannot exceed the contracted package amount';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_validate_package_receipt_total on public.package_receipts;
drop trigger if exists trg_validate_package_receipt_insert on public.package_receipts;
create trigger trg_validate_package_receipt_insert
before insert on public.package_receipts
for each row execute function public.validate_package_receipt_insert();
revoke all on function public.validate_package_receipt_insert() from public, anon, authenticated;

-- 6) Reembolso: primeiro identifica o pacote, depois trava o pacote e somente
-- entao relê o recebimento e soma reembolsos, evitando validar estado obsoleto.
create or replace function public.validate_package_receipt_refund()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_package_id uuid;
  v_receipt_amount numeric(10,2);
  v_existing_refunds numeric(10,2);
begin
  select pr.student_package_id
    into v_package_id
  from public.package_receipts pr
  where pr.school_id = new.school_id
    and pr.id = new.package_receipt_id;

  if not found then
    raise exception 'Package receipt not found for refund';
  end if;

  perform 1
  from public.student_packages sp
  where sp.school_id = new.school_id
    and sp.id = v_package_id
  for update;

  if not found then
    raise exception 'Student package not found for refund';
  end if;

  -- Releitura ocorre depois do lock comum do pacote.
  perform 1
  from public.package_receipts pr
  where pr.school_id = new.school_id
    and pr.id = new.package_receipt_id
    and pr.student_package_id = v_package_id;

  if not found then
    raise exception 'Package receipt changed or not found';
  end if;

  if exists (
    select 1 from public.package_receipt_voids pv
    where pv.school_id = new.school_id
      and pv.package_receipt_id = new.package_receipt_id
  ) then
    raise exception 'Voided receipts cannot be refunded';
  end if;

  select pr.amount
    into v_receipt_amount
  from public.package_receipts pr
  where pr.school_id = new.school_id
    and pr.id = new.package_receipt_id;

  select coalesce(sum(prf.amount), 0)
    into v_existing_refunds
  from public.package_receipt_refunds prf
  where prf.school_id = new.school_id
    and prf.package_receipt_id = new.package_receipt_id;

  if v_existing_refunds + new.amount > v_receipt_amount then
    raise exception 'Total refunds cannot exceed the original receipt amount';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_validate_package_receipt_refund on public.package_receipt_refunds;
create trigger trg_validate_package_receipt_refund
before insert on public.package_receipt_refunds
for each row execute function public.validate_package_receipt_refund();
revoke all on function public.validate_package_receipt_refund() from public, anon, authenticated;

-- 7) Anulacao integral: adquire lock do pacote antes de verificar reembolsos
-- e grava evento unico; nao altera nem apaga o recebimento original.
create or replace function public.validate_package_receipt_void()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_package_id uuid;
  v_receipt_amount numeric(10,2);
  v_existing_refunds numeric(10,2);
begin
  select pr.student_package_id
    into v_package_id
  from public.package_receipts pr
  where pr.school_id = new.school_id
    and pr.id = new.package_receipt_id;

  if not found or v_package_id <> new.student_package_id then
    raise exception 'Package receipt not found for void';
  end if;

  perform 1
  from public.student_packages sp
  where sp.school_id = new.school_id
    and sp.id = v_package_id
  for update;

  if not found then
    raise exception 'Student package not found for void';
  end if;

  select pr.amount
    into v_receipt_amount
  from public.package_receipts pr
  where pr.school_id = new.school_id
    and pr.id = new.package_receipt_id
    and pr.student_package_id = v_package_id;

  if not found then
    raise exception 'Package receipt not found after package lock';
  end if;

  select coalesce(sum(prf.amount), 0)
    into v_existing_refunds
  from public.package_receipt_refunds prf
  where prf.school_id = new.school_id
    and prf.package_receipt_id = new.package_receipt_id;

  if v_existing_refunds > 0 then
    raise exception 'A receipt with refunds cannot be voided; register remaining refund events instead';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_validate_package_receipt_void on public.package_receipt_voids;
create trigger trg_validate_package_receipt_void
before insert on public.package_receipt_voids
for each row execute function public.validate_package_receipt_void();
revoke all on function public.validate_package_receipt_void() from public, anon, authenticated;

-- 8) Bloqueia conclusao quando a divida ultrapassa o limite. Primeiro trava pacote;
-- em seguida consulta a mesma funcao usada pela view administrativa.
create or replace function public.guard_package_debt_before_lesson_completion()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_school_limit numeric(10,2);
  v_outstanding numeric(10,2);
begin
  if old.status = 'completed' or new.status <> 'completed'
     or new.student_package_id is null then
    return new;
  end if;

  if old.status = 'cancelled' then
    raise exception 'Cancelled lessons cannot be completed';
  end if;

  perform 1
  from public.student_packages sp
  where sp.school_id = new.school_id
    and sp.id = new.student_package_id
  for update;

  if not found then
    raise exception 'Student package not found for this lesson';
  end if;

  select s.package_debt_limit
    into v_school_limit
  from public.schools s
  where s.id = new.school_id;

  v_outstanding := public.package_outstanding_amount(new.school_id, new.student_package_id);

  if v_outstanding > v_school_limit then
    raise exception 'Package debt exceeds the school configured limit. Outstanding: %, allowed: %',
      v_outstanding, v_school_limit;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_guard_package_debt_before_lesson_completion on public.lessons;
create trigger trg_guard_package_debt_before_lesson_completion
before update of status on public.lessons
for each row
when (old.status is distinct from 'completed' and new.status = 'completed')
execute function public.guard_package_debt_before_lesson_completion();
revoke all on function public.guard_package_debt_before_lesson_completion() from public, anon, authenticated;

-- 9) View e gatilho usam a mesma funcao para o saldo devedor.
create or replace view public.owner_student_package_balances
with (security_invoker = true)
as
select
  sp.id as student_package_id,
  sp.school_id,
  sp.student_id,
  sp.package_offer_id,
  sp.contracted_amount,
  (sp.contracted_amount - public.package_outstanding_amount(sp.school_id, sp.id))::numeric(10,2)
    as received_amount,
  public.package_outstanding_amount(sp.school_id, sp.id)::numeric(10,2)
    as outstanding_amount,
  sp.lessons_purchased,
  sp.lessons_used,
  (sp.lessons_purchased - sp.lessons_used) as lessons_remaining,
  sp.status,
  sp.expires_at
from public.student_packages sp;

revoke all on public.owner_student_package_balances from public, anon;
grant select on public.owner_student_package_balances to authenticated;

-- Eventos financeiros sao append-only. Exclusao em cascata ocorre apenas no ciclo
-- de vida administrativo da escola/pacote, nunca por permissao direta do cliente.
