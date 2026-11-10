-- KWMT migration 004: recebimentos, reembolsos rastreáveis e limite de dívida
-- Pré-requisito: migrations 001, 002 e 003 revisadas e aplicadas em ambiente de teste.
-- contracted_amount representa a venda; package_receipts representa somente caixa recebido.

-- 1) Limite máximo de saldo devedor permitido por pacote antes de consumir créditos.
-- Padrão 0 é deliberadamente conservador: exige quitação. A interface deve informar
-- que pagamentos parciais só liberam consumo após o proprietário configurar tolerância.
alter table public.schools
  add column if not exists package_debt_limit numeric(10,2) not null default 0
  check (package_debt_limit >= 0);

comment on column public.schools.package_debt_limit is
  'Saldo devedor máximo permitido por pacote para consumir créditos. Zero exige quitação; pagamentos parciais exigem configuração explícita pelo proprietário.';

-- 2) Cada entrada de caixa é um recebimento independente.
create table if not exists public.package_receipts (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.schools(id) on delete cascade,
  student_package_id uuid not null,
  amount numeric(10,2) not null check (amount > 0),
  payment_method text not null
    check (payment_method in ('cash','pix','credit_card','debit_card','bank_transfer','other')),
  status text not null default 'received'
    check (status in ('received','void')),
  received_at timestamptz not null default now(),
  reference text,
  notes text,
  received_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  foreign key (school_id, student_package_id)
    references public.student_packages(school_id, id) on delete cascade
);

create index if not exists idx_package_receipts_package_date
  on public.package_receipts(school_id, student_package_id, received_at);

alter table public.package_receipts enable row level security;

drop policy if exists "owners manage package receipts" on public.package_receipts;
create policy "owners manage package receipts"
on public.package_receipts
for all to authenticated
using (public.is_school_owner(school_id))
with check (public.is_school_owner(school_id));

revoke all on public.package_receipts from anon;
grant select, insert, update, delete on public.package_receipts to authenticated;

-- 3) Histórico append-only de reembolsos. Cada estorno é um evento individual,
-- preservando valor, data, motivo, meio e usuário que registrou a movimentação.
create table if not exists public.package_receipt_refunds (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.schools(id) on delete cascade,
  package_receipt_id uuid not null,
  amount numeric(10,2) not null check (amount > 0),
  payment_method text not null
    check (payment_method in ('cash','pix','credit_card','debit_card','bank_transfer','other')),
  refunded_at timestamptz not null default now(),
  reason text not null,
  recorded_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  foreign key (school_id, package_receipt_id)
    references public.package_receipts(school_id, id) on delete cascade
);

create index if not exists idx_package_receipt_refunds_receipt_date
  on public.package_receipt_refunds(school_id, package_receipt_id, refunded_at);

alter table public.package_receipt_refunds enable row level security;

drop policy if exists "owners read package receipt refunds" on public.package_receipt_refunds;
create policy "owners read package receipt refunds"
on public.package_receipt_refunds
for select to authenticated
using (public.is_school_owner(school_id));

drop policy if exists "owners record package receipt refunds" on public.package_receipt_refunds;
create policy "owners record package receipt refunds"
on public.package_receipt_refunds
for insert to authenticated
with check (public.is_school_owner(school_id));

revoke all on public.package_receipt_refunds from anon, authenticated;
grant select, insert on public.package_receipt_refunds to authenticated;
-- Sem UPDATE/DELETE: correções devem ser registradas como novos eventos compensatórios.

-- 4) Valida que recebimentos líquidos nunca ultrapassem o valor contratado.
-- O lock do pacote serializa recebimentos e reembolsos relativos ao mesmo pacote.
create or replace function public.validate_package_receipt_total()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_contracted_amount numeric(10,2);
  v_existing_net numeric(10,2);
  v_refunded_for_receipt numeric(10,2);
  v_new_net numeric(10,2);
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

  select coalesce(sum(prf.amount), 0)
    into v_refunded_for_receipt
  from public.package_receipt_refunds prf
  where prf.school_id = new.school_id
    and prf.package_receipt_id = new.id;

  if v_refunded_for_receipt > new.amount then
    raise exception 'Receipt amount cannot be lower than its recorded refunds';
  end if;

  if new.status = 'void' and v_refunded_for_receipt > 0 then
    raise exception 'A receipt with recorded refunds cannot be voided; register a compensating event';
  end if;

  select coalesce(sum(
    case when pr.status = 'received'
      then pr.amount - coalesce(refunds.refunded_amount, 0)
      else 0
    end
  ), 0)
    into v_existing_net
  from public.package_receipts pr
  left join (
    select package_receipt_id, sum(amount) as refunded_amount
    from public.package_receipt_refunds
    where school_id = new.school_id
    group by package_receipt_id
  ) refunds on refunds.package_receipt_id = pr.id
  where pr.school_id = new.school_id
    and pr.student_package_id = new.student_package_id
    and pr.id <> new.id;

  v_new_net := case
    when new.status = 'received' then new.amount - v_refunded_for_receipt
    else 0
  end;

  if v_existing_net + v_new_net > v_contracted_amount then
    raise exception 'Net package receipts cannot exceed the contracted package amount';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_validate_package_receipt_total on public.package_receipts;
create trigger trg_validate_package_receipt_total
before insert or update on public.package_receipts
for each row execute function public.validate_package_receipt_total();

revoke all on function public.validate_package_receipt_total() from public, anon, authenticated;

-- 5) Valida cada reembolso contra o saldo ainda reembolsável do recebimento.
-- O lock do pacote evita corrida com outros recebimentos/reembolsos do mesmo pacote.
create or replace function public.validate_package_receipt_refund()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_receipt_amount numeric(10,2);
  v_receipt_status text;
  v_package_id uuid;
  v_existing_refunds numeric(10,2);
begin
  select pr.amount, pr.status, pr.student_package_id
    into v_receipt_amount, v_receipt_status, v_package_id
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

  if v_receipt_status <> 'received' then
    raise exception 'Only received payments can be refunded';
  end if;

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

-- 6) Impede consumo de crédito quando a dívida do pacote excede o limite da escola.
create or replace function public.guard_package_debt_before_lesson_completion()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_contracted_amount numeric(10,2);
  v_school_limit numeric(10,2);
  v_received_net numeric(10,2);
  v_outstanding numeric(10,2);
begin
  if old.status = 'completed' or new.status <> 'completed'
     or new.student_package_id is null then
    return new;
  end if;

  if old.status = 'cancelled' then
    raise exception 'Cancelled lessons cannot be completed';
  end if;

  select sp.contracted_amount
    into v_contracted_amount
  from public.student_packages sp
  where sp.id = new.student_package_id
    and sp.school_id = new.school_id
  for update;

  if not found then
    raise exception 'Student package not found for this lesson';
  end if;

  select s.package_debt_limit
    into v_school_limit
  from public.schools s
  where s.id = new.school_id;

  select coalesce(sum(pr.amount - coalesce(refunds.refunded_amount, 0)), 0)
    into v_received_net
  from public.package_receipts pr
  left join (
    select package_receipt_id, sum(amount) as refunded_amount
    from public.package_receipt_refunds
    where school_id = new.school_id
    group by package_receipt_id
  ) refunds on refunds.package_receipt_id = pr.id
  where pr.school_id = new.school_id
    and pr.student_package_id = new.student_package_id
    and pr.status = 'received';

  v_outstanding := greatest(v_contracted_amount - v_received_net, 0);

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

-- 7) Visão administrativa: contratado, recebido líquido, dívida e créditos restantes.
create or replace view public.owner_student_package_balances
with (security_invoker = true)
as
select
  sp.id as student_package_id,
  sp.school_id,
  sp.student_id,
  sp.package_offer_id,
  sp.contracted_amount,
  coalesce(receipts.received_amount, 0)::numeric(10,2) as received_amount,
  greatest(
    sp.contracted_amount - coalesce(receipts.received_amount, 0),
    0
  )::numeric(10,2) as outstanding_amount,
  sp.lessons_purchased,
  sp.lessons_used,
  (sp.lessons_purchased - sp.lessons_used) as lessons_remaining,
  sp.status,
  sp.expires_at
from public.student_packages sp
left join (
  select
    pr.school_id,
    pr.student_package_id,
    sum(pr.amount - coalesce(refunds.refunded_amount, 0)) as received_amount
  from public.package_receipts pr
  left join (
    select package_receipt_id, sum(amount) as refunded_amount
    from public.package_receipt_refunds
    group by school_id, package_receipt_id
  ) refunds
    on refunds.school_id = pr.school_id
   and refunds.package_receipt_id = pr.id
  where pr.status = 'received'
  group by pr.school_id, pr.student_package_id
) receipts
  on receipts.school_id = sp.school_id
 and receipts.student_package_id = sp.id;

revoke all on public.owner_student_package_balances from public, anon;
grant select on public.owner_student_package_balances to authenticated;

-- A view respeita RLS owner-only das tabelas-base (security_invoker).
