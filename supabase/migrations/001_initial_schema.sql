-- KWMT initial multi-school schema
-- Apply this migration in Supabase SQL Editor after reviewing it.
-- No API keys or passwords belong in this file.

create extension if not exists pgcrypto;
create extension if not exists btree_gist;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  created_at timestamptz not null default now()
);

create table if not exists public.schools (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  brand_name text,
  logo_url text,
  contact_phone text,
  operation_type text not null default 'surf_school'
    check (operation_type in ('surf_school','independent_instructor')),
  public_profile_enabled boolean not null default false,
  description text,
  city text,
  state text,
  service_area text,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

-- One school or instructor may register multiple teaching locations.
create table if not exists public.school_locations (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.schools(id) on delete cascade,
  location_name text not null,
  address_line text,
  address_number text,
  neighborhood text,
  city text not null,
  state text not null,
  postal_code text,
  reference_point text,
  latitude numeric(9,6),
  longitude numeric(9,6),
  is_primary boolean not null default false,
  public_visible boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (school_id, id),
  check ((latitude is null and longitude is null)
      or (latitude between -90 and 90 and longitude between -180 and 180))
);

create unique index if not exists idx_school_locations_one_primary
  on public.school_locations(school_id)
  where is_primary = true and active = true;

create index if not exists idx_school_locations_school
  on public.school_locations(school_id, active);

-- Public directory view: only explicitly published schools and locations
-- are visible, and only non-sensitive fields are exposed.
create or replace view public.public_school_locations
with (security_barrier = true)
as
select
  s.id as school_id,
  coalesce(nullif(s.brand_name, ''), s.name) as display_name,
  s.operation_type,
  s.logo_url,
  s.description,
  l.id as location_id,
  l.location_name,
  l.address_line,
  l.address_number,
  l.neighborhood,
  l.city,
  l.state,
  l.postal_code,
  l.reference_point,
  l.latitude,
  l.longitude,
  l.is_primary
from public.schools s
join public.school_locations l on l.school_id = s.id
where s.public_profile_enabled = true
  and l.public_visible = true
  and l.active = true;

create table if not exists public.school_members (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.schools(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('owner','teacher')),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (school_id, user_id)
);

create table if not exists public.teachers (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.schools(id) on delete cascade,
  user_id uuid references auth.users(id) on delete set null,
  name text not null,
  hourly_rate numeric(10,2) not null default 0 check (hourly_rate >= 0),
  half_hour_rate numeric(10,2) not null default 0 check (half_hour_rate >= 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (school_id, user_id),
  unique (school_id, id)
);

create table if not exists public.students (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.schools(id) on delete cascade,
  name text not null,
  created_at timestamptz not null default now(),
  unique (school_id, id)
);

-- Sensitive student contact details are stored separately so teachers
-- cannot read them through the ordinary students table.
create table if not exists public.student_private_details (
  student_id uuid primary key,
  school_id uuid not null references public.schools(id) on delete cascade,
  phone text,
  notes text,
  created_at timestamptz not null default now(),
  foreign key (school_id, student_id)
    references public.students(school_id, id) on delete cascade
);

create table if not exists public.lessons (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.schools(id) on delete cascade,
  student_id uuid not null,
  teacher_id uuid not null,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  status text not null default 'scheduled'
    check (status in ('scheduled','completed','cancelled')),
  attendance_confirmed_at timestamptz,
  attendance_confirmed_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  check (ends_at > starts_at),
  unique (school_id, id),
  foreign key (school_id, student_id) references public.students(school_id, id),
  foreign key (school_id, teacher_id) references public.teachers(school_id, id)
);

create table if not exists public.equipment (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.schools(id) on delete cascade,
  name text not null,
  category text,
  hourly_price numeric(10,2) not null default 0 check (hourly_price >= 0),
  daily_price numeric(10,2) not null default 0 check (daily_price >= 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (school_id, id)
);

create table if not exists public.rentals (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.schools(id) on delete cascade,
  equipment_id uuid not null,
  customer_name text not null,
  customer_phone text,
  starts_at timestamptz not null,
  due_at timestamptz not null,
  returned_at timestamptz,
  status text not null default 'checked_out'
    check (status in ('reserved','checked_out','returned','cancelled')),
  total_amount numeric(10,2) not null default 0 check (total_amount >= 0),
  paid boolean not null default false,
  created_at timestamptz not null default now(),
  check (due_at > starts_at),
  foreign key (school_id, equipment_id) references public.equipment(school_id, id)
);

create table if not exists public.school_expenses (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.schools(id) on delete cascade,
  description text not null,
  amount numeric(10,2) not null check (amount >= 0),
  expense_date date not null default current_date,
  created_at timestamptz not null default now()
);

create table if not exists public.lesson_payouts (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.schools(id) on delete cascade,
  lesson_id uuid not null,
  teacher_id uuid not null,
  amount numeric(10,2) not null check (amount >= 0),
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  unique (school_id, lesson_id),
  foreign key (school_id, lesson_id) references public.lessons(school_id, id) on delete cascade,
  foreign key (school_id, teacher_id) references public.teachers(school_id, id)
);

-- A payout can only be created for a completed, attendance-confirmed lesson,
-- and the teacher must be the teacher assigned to that lesson.
create or replace function public.validate_lesson_payout()
returns trigger
language plpgsql
security definer
set search_path = public
as $
declare
  lesson_status text;
  lesson_confirmed_at timestamptz;
  lesson_teacher uuid;
begin
  select status, attendance_confirmed_at, teacher_id
    into lesson_status, lesson_confirmed_at, lesson_teacher
  from public.lessons
  where school_id = new.school_id and id = new.lesson_id;

  if lesson_status is distinct from 'completed'
     or lesson_confirmed_at is null then
    raise exception 'Payout requires a completed and confirmed lesson';
  end if;

  if lesson_teacher is distinct from new.teacher_id then
    raise exception 'Payout teacher must match the lesson teacher';
  end if;

  return new;
end;
$;

drop trigger if exists trg_validate_lesson_payout on public.lesson_payouts;
create trigger trg_validate_lesson_payout
before insert or update on public.lesson_payouts
for each row execute function public.validate_lesson_payout();

-- Keep audit records server-generated and prevent clients from forging them.
create or replace function public.write_kwmt_audit_log()
returns trigger
language plpgsql
security definer
set search_path = public
as $
declare
  row_school uuid;
  row_id text;
  event_name text;
begin
  if tg_op = 'DELETE' then
    row_school := old.school_id;
    row_id := old.id::text;
    event_name := 'deleted';
  elsif tg_op = 'UPDATE' then
    row_school := new.school_id;
    row_id := new.id::text;
    event_name := 'updated';
  else
    row_school := new.school_id;
    row_id := new.id::text;
    event_name := 'created';
  end if;

  insert into public.audit_logs(school_id, actor_id, action, entity_table, entity_id)
  values (row_school, auth.uid(), event_name, tg_table_name, row_id);

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$;

create table if not exists public.audit_logs (
  id bigint generated always as identity primary key,
  school_id uuid not null references public.schools(id) on delete cascade,
  actor_id uuid references auth.users(id),
  action text not null,
  entity_table text not null,
  entity_id text,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists idx_members_user on public.school_members(user_id);
create index if not exists idx_teachers_user on public.teachers(user_id);
create index if not exists idx_students_school on public.students(school_id);
create index if not exists idx_lessons_school_start on public.lessons(school_id, starts_at);
create index if not exists idx_lessons_teacher_start on public.lessons(teacher_id, starts_at);
create index if not exists idx_rentals_school_start on public.rentals(school_id, starts_at);

-- Prevent overlapping bookings. Adjacent bookings are allowed (end = next start).
do $
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'lessons_teacher_no_overlap'
      and conrelid = 'public.lessons'::regclass
  ) then
    alter table public.lessons
      add constraint lessons_teacher_no_overlap
      exclude using gist (
        teacher_id with =,
        tstzrange(starts_at, ends_at, '[)') with &&
      )
      where (status = 'scheduled');
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'rentals_equipment_no_overlap'
      and conrelid = 'public.rentals'::regclass
  ) then
    alter table public.rentals
      add constraint rentals_equipment_no_overlap
      exclude using gist (
        equipment_id with =,
        tstzrange(starts_at, due_at, '[)') with &&
      )
      where (status in ('reserved', 'checked_out'));
  end if;
end;
$;

create or replace function public.is_school_member(target_school uuid)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.school_members m
    where m.school_id = target_school
      and m.user_id = auth.uid()
      and m.active = true
  );
$$;

create or replace function public.is_school_owner(target_school uuid)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.school_members m
    where m.school_id = target_school
      and m.user_id = auth.uid()
      and m.role = 'owner'
      and m.active = true
  );
$$;

create or replace function public.is_assigned_teacher(target_teacher uuid)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.teachers t
    join public.school_members m
      on m.school_id = t.school_id and m.user_id = t.user_id
    where t.id = target_teacher
      and t.user_id = auth.uid()
      and t.active = true
      and m.role = 'teacher'
      and m.active = true
  );
$$;

create or replace function public.create_school(school_name text, operation_kind text default 'surf_school')
returns uuid
language plpgsql security definer
set search_path = public
as $$
declare new_school_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;
  if nullif(trim(school_name), '') is null then
    raise exception 'School or professional name is required';
  end if;
  if operation_kind not in ('surf_school','independent_instructor') then
    raise exception 'Invalid operation type';
  end if;

  insert into public.profiles(id)
  values (auth.uid())
  on conflict (id) do nothing;

  insert into public.schools(name, operation_type, created_by)
  values (trim(school_name), operation_kind, auth.uid())
  returning id into new_school_id;

  insert into public.school_members(school_id, user_id, role)
  values (new_school_id, auth.uid(), 'owner');

  return new_school_id;
end;
$$;

create or replace function public.confirm_lesson_attendance(target_lesson uuid)
returns void
language plpgsql security definer
set search_path = public
as $
declare
  lesson_school uuid;
  lesson_teacher uuid;
  lesson_end timestamptz;
  lesson_status text;
begin
  select school_id, teacher_id, ends_at, status
    into lesson_school, lesson_teacher, lesson_end, lesson_status
  from public.lessons
  where id = target_lesson
  for update;

  if lesson_school is null then
    raise exception 'Lesson not found';
  end if;

  if not public.is_school_owner(lesson_school)
     and not public.is_assigned_teacher(lesson_teacher) then
    raise exception 'Not authorized';
  end if;

  if lesson_status <> 'scheduled' then
    raise exception 'Only scheduled lessons can be confirmed';
  end if;

  if lesson_end > now() then
    raise exception 'A lesson can only be confirmed after its scheduled end';
  end if;

  update public.lessons
  set status = 'completed',
      attendance_confirmed_at = now(),
      attendance_confirmed_by = auth.uid()
  where id = target_lesson;

  insert into public.audit_logs(school_id, actor_id, action, entity_table, entity_id)
  values (lesson_school, auth.uid(), 'attendance_confirmed', 'lessons', target_lesson::text);
end;
$;

-- Automatically record owner-managed business data changes.
drop trigger if exists trg_audit_students on public.students;
create trigger trg_audit_students after insert or update or delete on public.students
for each row execute function public.write_kwmt_audit_log();

drop trigger if exists trg_audit_lessons on public.lessons;
create trigger trg_audit_lessons after insert or update or delete on public.lessons
for each row execute function public.write_kwmt_audit_log();

drop trigger if exists trg_audit_rentals on public.rentals;
create trigger trg_audit_rentals after insert or update or delete on public.rentals
for each row execute function public.write_kwmt_audit_log();

drop trigger if exists trg_audit_expenses on public.school_expenses;
create trigger trg_audit_expenses after insert or update or delete on public.school_expenses
for each row execute function public.write_kwmt_audit_log();

drop trigger if exists trg_audit_payouts on public.lesson_payouts;
create trigger trg_audit_payouts after insert or update or delete on public.lesson_payouts
for each row execute function public.write_kwmt_audit_log();

drop trigger if exists trg_audit_locations on public.school_locations;
create trigger trg_audit_locations after insert or update or delete on public.school_locations
for each row execute function public.write_kwmt_audit_log();

revoke all on function public.is_school_member(uuid) from public, anon;
revoke all on function public.is_school_owner(uuid) from public, anon;
revoke all on function public.is_assigned_teacher(uuid) from public, anon;
revoke all on function public.create_school(text, text) from public, anon;
revoke all on function public.confirm_lesson_attendance(uuid) from public, anon;
revoke all on function public.validate_lesson_payout() from public, anon;
revoke all on function public.write_kwmt_audit_log() from public, anon;

grant execute on function public.is_school_member(uuid) to authenticated;
grant execute on function public.is_school_owner(uuid) to authenticated;
grant execute on function public.is_assigned_teacher(uuid) to authenticated;

alter table public.profiles enable row level security;
alter table public.schools enable row level security;
alter table public.school_members enable row level security;
alter table public.school_locations enable row level security;
alter table public.teachers enable row level security;
alter table public.students enable row level security;
alter table public.student_private_details enable row level security;
alter table public.lessons enable row level security;
alter table public.equipment enable row level security;
alter table public.rentals enable row level security;
alter table public.school_expenses enable row level security;
alter table public.lesson_payouts enable row level security;
alter table public.audit_logs enable row level security;

drop policy if exists "profiles read own" on public.profiles;
create policy "profiles read own" on public.profiles
for select to authenticated using (id = auth.uid());
drop policy if exists "profiles update own" on public.profiles;
create policy "profiles update own" on public.profiles
for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists "schools owner read" on public.schools;
create policy "schools owner read" on public.schools
for select to authenticated using (public.is_school_owner(id));
drop policy if exists "schools owner update" on public.schools;
create policy "schools owner update" on public.schools
for update to authenticated using (public.is_school_owner(id)) with check (public.is_school_owner(id));

drop policy if exists "owner manages school locations" on public.school_locations;
create policy "owner manages school locations" on public.school_locations
for all to authenticated
using (public.is_school_owner(school_id))
with check (public.is_school_owner(school_id));

drop policy if exists "members self or owner read" on public.school_members;
create policy "members self or owner read" on public.school_members
for select to authenticated using (user_id = auth.uid() or public.is_school_owner(school_id));
drop policy if exists "owner manages members" on public.school_members;
create policy "owner manages members" on public.school_members
for all to authenticated using (public.is_school_owner(school_id)) with check (public.is_school_owner(school_id));

drop policy if exists "teachers owner or self read" on public.teachers;
create policy "teachers owner or self read" on public.teachers
for select to authenticated using (public.is_school_owner(school_id) or user_id = auth.uid());
drop policy if exists "owner manages teachers" on public.teachers;
create policy "owner manages teachers" on public.teachers
for all to authenticated using (public.is_school_owner(school_id)) with check (public.is_school_owner(school_id));

drop policy if exists "students owner or assigned teacher read" on public.students;
create policy "students owner or assigned teacher read" on public.students
for select to authenticated using (
  public.is_school_owner(school_id)
  or exists (
    select 1 from public.lessons l
    where l.school_id = students.school_id
      and l.student_id = students.id
      and public.is_assigned_teacher(l.teacher_id)
  )
);
drop policy if exists "owner manages students" on public.students;
create policy "owner manages students" on public.students
for all to authenticated using (public.is_school_owner(school_id)) with check (public.is_school_owner(school_id));

drop policy if exists "student private details owner only" on public.student_private_details;
create policy "student private details owner only" on public.student_private_details
for all to authenticated
using (public.is_school_owner(school_id))
with check (public.is_school_owner(school_id));

drop policy if exists "lessons owner or assigned teacher read" on public.lessons;
create policy "lessons owner or assigned teacher read" on public.lessons
for select to authenticated using (
  public.is_school_owner(school_id) or public.is_assigned_teacher(teacher_id)
);
drop policy if exists "owner manages lessons" on public.lessons;
create policy "owner manages lessons" on public.lessons
for all to authenticated using (public.is_school_owner(school_id)) with check (public.is_school_owner(school_id));

drop policy if exists "equipment owner read" on public.equipment;
create policy "equipment owner read" on public.equipment
for select to authenticated using (public.is_school_owner(school_id));
drop policy if exists "owner manages equipment" on public.equipment;
create policy "owner manages equipment" on public.equipment
for all to authenticated using (public.is_school_owner(school_id)) with check (public.is_school_owner(school_id));

drop policy if exists "rentals owner only" on public.rentals;
create policy "rentals owner only" on public.rentals
for all to authenticated using (public.is_school_owner(school_id)) with check (public.is_school_owner(school_id));

drop policy if exists "expenses owner only" on public.school_expenses;
create policy "expenses owner only" on public.school_expenses
for all to authenticated using (public.is_school_owner(school_id)) with check (public.is_school_owner(school_id));

drop policy if exists "payouts owner only" on public.lesson_payouts;
create policy "payouts owner only" on public.lesson_payouts
for all to authenticated using (public.is_school_owner(school_id)) with check (public.is_school_owner(school_id));

drop policy if exists "audit owner only" on public.audit_logs;
create policy "audit owner only" on public.audit_logs
for select to authenticated using (public.is_school_owner(school_id));
drop policy if exists "audit insert member" on public.audit_logs;
drop policy if exists "audit insert server only" on public.audit_logs;
-- Audit rows are inserted only by trusted database triggers/functions.

revoke all on public.schools, public.school_members, public.school_locations, public.teachers, public.students,
  public.student_private_details, public.lessons, public.equipment, public.rentals, public.school_expenses,
  public.lesson_payouts, public.audit_logs from anon;

grant select, update on public.profiles to authenticated;
grant select, update on public.schools to authenticated;
grant select, insert, update, delete on public.school_locations to authenticated;
revoke all on public.public_school_locations from public;
grant select on public.public_school_locations to anon, authenticated;
grant select, insert, update, delete on public.school_members to authenticated;
grant select, insert, update, delete on public.teachers to authenticated;
grant select, insert, update, delete on public.students to authenticated;
grant select, insert, update, delete on public.student_private_details to authenticated;
grant select, insert, update, delete on public.lessons to authenticated;
grant select, insert, update, delete on public.equipment to authenticated;
grant select, insert, update, delete on public.rentals to authenticated;
grant select, insert, update, delete on public.school_expenses to authenticated;
grant select, insert, update, delete on public.lesson_payouts to authenticated;
grant select on public.audit_logs to authenticated;
revoke insert, update, delete on public.audit_logs from authenticated;

grant execute on function public.create_school(text, text) to authenticated;
grant execute on function public.confirm_lesson_attendance(uuid) to authenticated;
