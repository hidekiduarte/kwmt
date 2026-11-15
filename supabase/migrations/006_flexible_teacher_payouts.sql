-- KWMT migration 006: repasses flexíveis por escola, professor e modalidade.
-- Aplicar somente após revisar as migrations anteriores. Não executa automaticamente.

alter table public.teacher_payout_rules
  rename column payout_amount to payout_value;

alter table public.teacher_payout_rules
  add column payout_type text not null default 'fixed_amount'
    check (payout_type in ('fixed_amount','percentage'));

alter table public.teacher_payout_rules
  add constraint teacher_payout_rules_value_check
  check (payout_value >= 0 and (payout_type <> 'percentage' or payout_value <= 100));

create or replace function public.record_lesson_financials()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_gross numeric(10,2);
  v_payout numeric(10,2);
  v_rule_value numeric(10,2);
  v_rule_type text;
  v_package_price numeric(10,2);
  v_lessons_purchased integer;
  v_lessons_used integer;
  v_package_status text;
  v_package_expires_at timestamptz;
  v_package_student_id uuid;
  v_lesson_price numeric(10,2);
begin
  if new.status <> 'completed' or old.status = 'completed' then return new; end if;
  if old.status = 'cancelled' then raise exception 'Cancelled lessons cannot be completed'; end if;
  if new.attendance_confirmed_at is null or new.attendance_confirmed_by is null then
    raise exception 'Lesson completion requires confirmed attendance';
  end if;
  if exists (select 1 from public.lesson_financial_records r where r.school_id = new.school_id and r.lesson_id = new.id) then
    return new;
  end if;

  if new.student_package_id is not null then
    select sp.contracted_amount, sp.lessons_purchased, sp.lessons_used,
           sp.status, sp.expires_at, sp.student_id
      into v_package_price, v_lessons_purchased, v_lessons_used,
           v_package_status, v_package_expires_at, v_package_student_id
    from public.student_packages sp
    where sp.school_id = new.school_id and sp.id = new.student_package_id
    for update;
    if not found then raise exception 'Student package not found for this school'; end if;
    if v_package_student_id <> new.student_id then raise exception 'Student package does not belong to the lesson student'; end if;
    if v_package_status <> 'active' or (v_package_expires_at is not null and v_package_expires_at <= now()) then
      raise exception 'Student package is not active or has expired';
    end if;
    if v_package_expires_at is not null and new.ends_at > v_package_expires_at then
      raise exception 'Lesson must end on or before the student package expiration date';
    end if;
    if v_lessons_used >= v_lessons_purchased then raise exception 'Student package has no remaining lessons'; end if;
    v_gross := round(v_package_price / v_lessons_purchased, 2);
    if v_lessons_used + 1 = v_lessons_purchased then
      v_gross := v_package_price - (round(v_package_price / v_lessons_purchased, 2) * (v_lessons_purchased - 1));
    end if;
    update public.student_packages
      set lessons_used = lessons_used + 1,
          status = case when lessons_used + 1 >= lessons_purchased then 'completed' else status end
    where school_id = new.school_id and id = new.student_package_id;
  else
    if new.lesson_type_id is null then raise exception 'A lesson type is required for a non-package lesson'; end if;
    select lt.price into v_lesson_price
    from public.lesson_types lt
    where lt.school_id = new.school_id and lt.id = new.lesson_type_id and lt.active = true;
    if not found then raise exception 'Active lesson type not found for this school'; end if;
    v_gross := v_lesson_price;
  end if;

  -- Modalidade específica tem precedência; regra geral (NULL) é fallback.
  select pr.payout_type, pr.payout_value
    into v_rule_type, v_rule_value
  from public.teacher_payout_rules pr
  where pr.school_id = new.school_id
    and pr.teacher_id = new.teacher_id
    and (pr.lesson_type_id = new.lesson_type_id or pr.lesson_type_id is null)
  order by (pr.lesson_type_id is not null) desc
  limit 1;
  if not found then raise exception 'No payout rule configured for this teacher'; end if;

  if v_rule_type = 'percentage' then
    v_payout := round(v_gross * v_rule_value / 100, 2);
  else
    v_payout := v_rule_value;
  end if;

  insert into public.lesson_financial_records (
    school_id, lesson_id, lesson_type_id, student_package_id,
    gross_amount, teacher_payout_amount
  ) values (
    new.school_id, new.id, new.lesson_type_id, new.student_package_id,
    v_gross, v_payout
  ) on conflict (school_id, lesson_id) do nothing;
  return new;
end;
$$;

revoke all on function public.record_lesson_financials() from public, anon, authenticated;

create or replace function public.create_school_teacher(
  teacher_name text,
  payout_type text,
  payout_value numeric
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_school_id uuid;
  v_teacher_id uuid;
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;
  if nullif(trim(teacher_name), '') is null then raise exception 'Teacher name is required'; end if;
  if payout_type not in ('fixed_amount','percentage') then raise exception 'Invalid payout type'; end if;
  if payout_value is null or payout_value < 0 or (payout_type = 'percentage' and payout_value > 100) then
    raise exception 'Invalid payout value';
  end if;
  select m.school_id into v_school_id from public.school_members m
    where m.user_id = v_user_id and m.role = 'owner' and m.active = true
    order by m.created_at limit 1;
  if v_school_id is null then raise exception 'Active school owner membership required'; end if;
  if (select count(*) from public.school_members m where m.user_id = v_user_id and m.role = 'owner' and m.active = true) <> 1 then
    raise exception 'Select one active school before managing teachers';
  end if;
  insert into public.teachers(school_id, name, active)
    values (v_school_id, trim(teacher_name), true) returning id into v_teacher_id;
  insert into public.teacher_payout_rules(school_id, teacher_id, lesson_type_id, payout_type, payout_value)
    values (v_school_id, v_teacher_id, null, payout_type, payout_value);
  return jsonb_build_object('teacher_id', v_teacher_id, 'teacher_name', trim(teacher_name));
end;
$$;

create or replace function public.save_teacher_payout_rule(
  target_teacher uuid,
  target_lesson_type uuid,
  payout_type text,
  payout_value numeric
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_school_id uuid;
  v_rule_id uuid;
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;
  if payout_type not in ('fixed_amount','percentage') then raise exception 'Invalid payout type'; end if;
  if payout_value is null or payout_value < 0 or (payout_type = 'percentage' and payout_value > 100) then
    raise exception 'Invalid payout value';
  end if;
  select m.school_id into v_school_id from public.school_members m
    where m.user_id = v_user_id and m.role = 'owner' and m.active = true
    order by m.created_at limit 1;
  if v_school_id is null then raise exception 'Active school owner membership required'; end if;
  if (select count(*) from public.school_members m where m.user_id = v_user_id and m.role = 'owner' and m.active = true) <> 1 then
    raise exception 'Select one active school before managing payout rules';
  end if;
  if not exists (select 1 from public.teachers t where t.id = target_teacher and t.school_id = v_school_id and t.active = true) then
    raise exception 'Teacher not found for this school';
  end if;
  if target_lesson_type is not null and not exists (
    select 1 from public.lesson_types lt where lt.id = target_lesson_type and lt.school_id = v_school_id and lt.active = true
  ) then raise exception 'Lesson type not found for this school'; end if;

  select r.id into v_rule_id from public.teacher_payout_rules r
    where r.school_id = v_school_id and r.teacher_id = target_teacher
      and r.lesson_type_id is not distinct from target_lesson_type
    limit 1 for update;
  if v_rule_id is null then
    insert into public.teacher_payout_rules(school_id, teacher_id, lesson_type_id, payout_type, payout_value)
      values (v_school_id, target_teacher, target_lesson_type, payout_type, payout_value)
      returning id into v_rule_id;
  else
    update public.teacher_payout_rules
      set payout_type = save_teacher_payout_rule.payout_type,
          payout_value = save_teacher_payout_rule.payout_value,
          updated_at = now()
      where id = v_rule_id and school_id = v_school_id;
  end if;
  return jsonb_build_object('rule_id', v_rule_id, 'teacher_id', target_teacher, 'lesson_type_id', target_lesson_type);
end;
$$;

revoke all on function public.create_school_teacher(text, text, numeric) from public, anon;
revoke all on function public.save_teacher_payout_rule(uuid, uuid, text, numeric) from public, anon;
grant execute on function public.create_school_teacher(text, text, numeric) to authenticated;
grant execute on function public.save_teacher_payout_rule(uuid, uuid, text, numeric) to authenticated;
