-- KWMT: preços flexíveis por escola e repasses individuais por professor
-- Migration aditiva: não altera registros existentes nem fixa valores comerciais.

create table if not exists public.lesson_types (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.schools(id) on delete cascade,
  name text not null,
  category text not null default 'other',
  duration_minutes integer not null default 60 check (duration_minutes > 0),
  price numeric(10,2) not null default 0 check (price >= 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (school_id, id)
);

-- Modelos de pacotes: o proprietário escolhe quantidade, validade e preço.
create table if not exists public.package_offers (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.schools(id) on delete cascade,
  name text not null,
  lesson_count integer not null check (lesson_count > 0),
  price numeric(10,2) not null check (price >= 0),
  validity_days integer check (validity_days is null or validity_days > 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (school_id, id)
);

-- Pacotes efetivamente vendidos a um aluno.
create table if not exists public.student_packages (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.schools(id) on delete cascade,
  student_id uuid not null,
  package_offer_id uuid not null,
  lessons_purchased integer not null check (lessons_purchased > 0),
  contracted_amount numeric(10,2) not null check (contracted_amount >= 0),
  purchased_at timestamptz not null default now(),
  expires_at timestamptz,
  status text not null default 'active'
    check (status in ('active','completed','expired','cancelled')),
  created_at timestamptz not null default now(),
  unique (school_id, id),
  foreign key (school_id, student_id) references public.students(school_id, id),
  foreign key (school_id, package_offer_id) references public.package_offers(school_id, id)
);

-- Regra individual: pode existir uma regra padrão por professor e regras
-- específicas por tipo de aula. O tipo específico tem prioridade.
create table if not exists public.teacher_payout_rules (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.schools(id) on delete cascade,
  teacher_id uuid not null,
  lesson_type_id uuid,
  payout_amount numeric(10,2) not null check (payout_amount >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (school_id, teacher_id) references public.teachers(school_id, id) on delete cascade,
  foreign key (school_id, lesson_type_id) references public.lesson_types(school_id, id) on delete cascade
);

create unique index if not exists teacher_payout_rules_default_unique
  on public.teacher_payout_rules(school_id, teacher_id)
  where lesson_type_id is null;
create unique index if not exists teacher_payout_rules_type_unique
  on public.teacher_payout_rules(school_id, teacher_id, lesson_type_id)
  where lesson_type_id is not null;

-- Fotografia financeira da aula no momento do registro. Alterar preços depois
-- não modifica o faturamento histórico nem o repasse já calculado.
create table if not exists public.lesson_financial_records (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.schools(id) on delete cascade,
  lesson_id uuid not null,
  lesson_type_id uuid,
  student_package_id uuid,
  gross_amount numeric(10,2) not null default 0 check (gross_amount >= 0),
  teacher_payout_amount numeric(10,2) not null default 0 check (teacher_payout_amount >= 0),
  created_at timestamptz not null default now(),
  unique (school_id, lesson_id),
  foreign key (school_id, lesson_id) references public.lessons(school_id, id) on delete cascade,
  foreign key (school_id, lesson_type_id) references public.lesson_types(school_id, id),
  foreign key (school_id, student_package_id) references public.student_packages(school_id, id)
);

create index if not exists idx_lesson_types_school_active
  on public.lesson_types(school_id, active);
create index if not exists idx_package_offers_school_active
  on public.package_offers(school_id, active);
create index if not exists idx_student_packages_student
  on public.student_packages(school_id, student_id);
create index if not exists idx_payout_rules_teacher
  on public.teacher_payout_rules(school_id, teacher_id);

alter table public.lesson_types enable row level security;
alter table public.package_offers enable row level security;
alter table public.student_packages enable row level security;
alter table public.teacher_payout_rules enable row level security;
alter table public.lesson_financial_records enable row level security;

drop policy if exists "owner manages lesson types" on public.lesson_types;
create policy "owner manages lesson types" on public.lesson_types
  for all to authenticated
  using (public.is_school_owner(school_id))
  with check (public.is_school_owner(school_id));

drop policy if exists "owner manages package offers" on public.package_offers;
create policy "owner manages package offers" on public.package_offers
  for all to authenticated
  using (public.is_school_owner(school_id))
  with check (public.is_school_owner(school_id));

drop policy if exists "owner manages student packages" on public.student_packages;
create policy "owner manages student packages" on public.student_packages
  for all to authenticated
  using (public.is_school_owner(school_id))
  with check (public.is_school_owner(school_id));

drop policy if exists "owner manages payout rules" on public.teacher_payout_rules;
create policy "owner manages payout rules" on public.teacher_payout_rules
  for all to authenticated
  using (public.is_school_owner(school_id))
  with check (public.is_school_owner(school_id));

drop policy if exists "owner reads lesson financial records" on public.lesson_financial_records;
create policy "owner reads lesson financial records" on public.lesson_financial_records
  for all to authenticated
  using (public.is_school_owner(school_id))
  with check (public.is_school_owner(school_id));

revoke all on public.lesson_types, public.package_offers, public.student_packages,
  public.teacher_payout_rules, public.lesson_financial_records from anon;
grant select, insert on public.lesson_types, public.package_offers,
  public.student_packages, public.teacher_payout_rules, public.lesson_financial_records
  to authenticated;
grant update on public.lesson_types, public.package_offers,
  public.teacher_payout_rules, public.lesson_financial_records to authenticated;
-- O proprietário pode alterar o estado e a validade, mas não editar o contador
-- de créditos; lessons_used só é incrementado pelo gatilho financeiro.
grant update (status, expires_at) on public.student_packages to authenticated;
grant delete on public.lesson_types, public.package_offers,
  public.teacher_payout_rules, public.lesson_financial_records to authenticated;
-- Pacotes vendidos não podem ser apagados fisicamente: preserve o histórico e
-- use status = 'cancelled' para desativar um pacote sem destruir seus vínculos.

-- Impede que professores consultem os campos legados de remuneração na tabela
-- teachers. Donos configuram e consultam valores em teacher_payout_rules.
-- Mantemos as colunas antigas nesta migração para não apagar dados históricos.
revoke select on public.teachers from authenticated;
grant select (id, school_id, user_id, name, active, created_at)
  on public.teachers to authenticated;
