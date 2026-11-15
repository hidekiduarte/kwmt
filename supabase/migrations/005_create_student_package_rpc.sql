-- KWMT migration 005: criação atômica de aluno e pacote pelo proprietário.
-- Executar somente no projeto STAGING, depois das migrations 001 a 004.
-- Uma única RPC evita deixar aluno/pacote parcialmente criado se o recebimento falhar.

create or replace function public.create_student_package(
  student_name text,
  unit_price numeric,
  is_paid boolean default false,
  payment_method text default null,
  purchase_date date default current_date
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_school_id uuid;
  v_student_id uuid;
  v_offer_id uuid;
  v_package_id uuid;
  v_total numeric(10,2);
  v_purchased_at timestamptz;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  if nullif(trim(student_name), '') is null then
    raise exception 'Student name is required';
  end if;
  if unit_price is null or unit_price <= 0 then
    raise exception 'Unit price must be greater than zero';
  end if;
  if purchase_date is null then
    raise exception 'Purchase date is required';
  end if;
  if is_paid and payment_method not in ('cash','pix','credit_card','debit_card','bank_transfer','other') then
    raise exception 'A valid payment method is required for a paid package';
  end if;
  if not is_paid and payment_method is not null then
    raise exception 'Payment method must be empty for an unpaid package';
  end if;

  select m.school_id into v_school_id
  from public.school_members m
  where m.user_id = v_user_id and m.role = 'owner' and m.active = true
  order by m.created_at
  limit 1;

  if v_school_id is null then
    raise exception 'Active school owner membership required';
  end if;

  if (select count(*) from public.school_members m
      where m.user_id = v_user_id and m.role = 'owner' and m.active = true) > 1 then
    raise exception 'Multiple owner schools are not supported by this operation';
  end if;

  v_total := round(unit_price * 10, 2);
  v_purchased_at := purchase_date::timestamp at time zone 'America/Sao_Paulo';

  insert into public.students (school_id, name)
  values (v_school_id, trim(student_name))
  returning id into v_student_id;

  insert into public.package_offers (school_id, name, lesson_count, price, validity_days, active)
  values (v_school_id, 'Pacote de 10 aulas', 10, v_total, null, true)
  returning id into v_offer_id;

  insert into public.student_packages (
    school_id, student_id, package_offer_id, lessons_purchased,
    contracted_amount, purchased_at, expires_at, status
  ) values (
    v_school_id, v_student_id, v_offer_id, 10,
    v_total, v_purchased_at, null, 'active'
  ) returning id into v_package_id;

  if is_paid then
    insert into public.package_receipts (
      school_id, student_package_id, amount, payment_method, received_at
    ) values (
      v_school_id, v_package_id, v_total, payment_method, v_purchased_at
    );
  end if;

  return jsonb_build_object(
    'student_id', v_student_id,
    'student_name', trim(student_name),
    'student_package_id', v_package_id,
    'package_offer_id', v_offer_id,
    'lessons_purchased', 10,
    'contracted_amount', v_total,
    'is_paid', is_paid,
    'purchased_at', v_purchased_at
  );
end;
$$;

revoke all on function public.create_student_package(text, numeric, boolean, text, date) from public, anon;
grant execute on function public.create_student_package(text, numeric, boolean, text, date) to authenticated;
