-- KWMT migration 004: recebimentos antecipados, pagamentos parciais e limite de dívida
-- Pré-requisito: migrations 001, 002 e 003 revisadas e aplicadas em ambiente de teste.
-- Não fixa preços nem valores comerciais; cada pacote usa seu próprio preço contratado.

-- 1) Limite máximo de saldo devedor permitido por pacote antes de consumir créditos.
-- Padrão 0: exige quitação. O proprietário pode configurar um limite maior por escola.
alter table public.schools
  add column if not exists package_debt_limit numeric(10,2) not null default 0
  check (package_debt_limit >= 0);

comment on column public.schools.package_debt_limit is
  'Saldo devedor máximo permitido por pacote para que novas aulas sejam consumidas. Zero exige quitação.';

-- 2) Recebimentos de pacotes. Cada pagamento parcial é um registro separado.
-- Reembolsos parciais são registrados em refunded_amount; void invalida o recebimento.
create table if not exists public.package_receipts (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.schools(id) on delete cascade,
  student_package_id uuid not null,
  amount numeric(10,2) not null check (amount > 0),
  refunded_amount numeric(10,2) not null default 0
    check (refunded_amount >= 0 and refunded_amount <= amount),
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

-- 3) Evita que a soma líquida dos recebimentos ultrapasse o preço contratado.
-- O lock no pacote serializa lançamentos simultâneos para o mesmo pacote.
create or replace function public.validate_package_receipt_total()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_package_price numeric(10,2);
  v_existing_net numeric(10,2);
  v_new_net numeric(10,2);
begin
  select sp.price_paid
    into v_package_price
  from public.student_packages sp
  where sp.school_id = new.school_id
    and sp.id = new.student_package_id
  for update;

  if not found then
    raise exception 'Student package not found for receipt';
  end if;

  select coalesce(sum(
    case when pr.status = 'received'
      then pr.amount - pr.refunded_amount
      else 0
    end
  ), 0)
    into v_existing_net
  from public.package_receipts pr
  where pr.school_id = new.school_id
    and pr.student_package_id = new.student_package_id
    and pr.id <> coalesce(new.id, '00000000-0000-0000-0000-000000000000'::uuid);

  v_new_net := case
    when new.status = 'received' then new.amount - new.refunded_amount
    else 0
  end;

  if v_existing_net + v_new_net > v_package_price then
    raise exception 'Net package receipts cannot exceed the contracted package price';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_validate_package_receipt_total on public.package_receipts;
create trigger trg_validate_package_receipt_total
before insert or update on public.package_receipts
for each row execute function public.validate_package_receipt_total();

revoke all on function public.validate_package_receipt_total() from public, anon, authenticated;

-- 4) Impede consumo de crédito quando a dívida do pacote excede o limite definido
-- pelo proprietário. O gatilho roda antes da conclusão; qualquer erro desfaz a transação.
create or replace function public.guard_package_debt_before_lesson_completion()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_package_price numeric(10,2);
  v_package_school uuid;
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

  select sp.price_paid, sp.school_id
    into v_package_price, v_package_school
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
  where s.id = v_package_school;

  select coalesce(sum(pr.amount - pr.refunded_amount), 0)
    into v_received_net
  from public.package_receipts pr
  where pr.school_id = new.school_id
    and pr.student_package_id = new.student_package_id
    and pr.status = 'received';

  v_outstanding := greatest(v_package_price - v_received_net, 0);

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

-- 5) Visão administrativa: valores contratados, recebidos, dívida e créditos restantes.
-- security_invoker garante que as políticas RLS das tabelas-base sejam respeitadas.
create or replace view public.owner_student_package_balances
with (security_invoker = true)
as
select
  sp.id as student_package_id,
  sp.school_id,
  sp.student_id,
  sp.package_offer_id,
  sp.price_paid as contracted_amount,
  coalesce(receipts.received_amount, 0)::numeric(10,2) as received_amount,
  greatest(
    sp.price_paid - coalesce(receipts.received_amount, 0),
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
    sum(pr.amount - pr.refunded_amount) as received_amount
  from public.package_receipts pr
  where pr.status = 'received'
  group by pr.school_id, pr.student_package_id
) receipts
  on receipts.school_id = sp.school_id
 and receipts.student_package_id = sp.id;

revoke all on public.owner_student_package_balances from public, anon;
grant select on public.owner_student_package_balances to authenticated;

-- A view depende da RLS owner-only já aplicada em student_packages na migration 002
-- e da política owner-only criada acima para package_receipts.
