-- KWMT initial multi-school schema
-- Apply this migration in Supabase SQL Editor after reviewing it.
-- No API keys or passwords belong in this file.

create extension if not exists pgcrypto;

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
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

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
  phone text,
  notes text,
  created_at timestamptz not null default now(),
  unique (school_id, id)
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

create or replace function public.create_school(school_name text)
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
    raise exception 'School name is required';
  end if;

  insert into public.profiles(id)
  values (auth.uid())
  on conflict (id) do nothing;

  insert into public.schools(name, created_by)
  values (trim(school_name), auth.uid())
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
as $$
declare lesson_school uuid;
declare lesson_teacher uuid;
begin
  select school_id, teacher_id into lesson_school, lesson_teacher
  from public.lessons where id = target_lesson;

  if lesson_school is null then
    raise exception 'Lesson not found';
  end if;

  if not public.is_school_owner(lesson_school)
     and not public.is_assigned_teacher(lesson_teacher) then
    raise exception 'Not authorized';
  end if;

  update public.lessons
  set status = 'completed',
      attendance_confirmed_at = now(),
      attendance_confirmed_by = auth.uid()
  where id = target_lesson;

  insert into public.audit_logs(school_id, actor_id, action, entity_table, entity_id)
  values (lesson_school, auth.uid(), 'attendance_confirmed', 'lessons', target_lesson::text);
end;
$$;

revoke all on function public.is_school_member(uuid) from public, anon;
revoke all on function public.is_school_owner(uuid) from public, anon;
revoke all on function public.is_assigned_teacher(uuid) from public, anon;
revoke all on function public.create_school(text) from public, anon;
revoke all on function public.confirm_lesson_attendance(uuid) from public, anon;

grant execute on function public.is_school_member(uuid) to authenticated;
grant execute on function public.is_school_owner(uuid) to authenticated;
grant execute on function public.is_assigned_teacher(uuid) to authenticated;

alter table public.profiles enable row level security;
alter table public.schools enable row level security;
alter table public.school_members enable row level security;
alter table public.teachers enable row level security;
alter table public.students enable row level security;
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
    join public.teachers t on t.id = l.teacher_id
    where l.student_id = students.id and t.user_id = auth.uid()
  )
);
drop policy if exists "owner manages students" on public.students;
create policy "owner manages students" on public.students
for all to authenticated using (public.is_school_owner(school_id)) with check (public.is_school_owner(school_id));

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
create policy "audit insert member" on public.audit_logs
for insert to authenticated with check (public.is_school_member(school_id) and actor_id = auth.uid());

revoke all on public.schools, public.school_members, public.teachers, public.students,
  public.lessons, public.equipment, public.rentals, public.school_expenses,
  public.lesson_payouts, public.audit_logs from anon;

grant select, update on public.profiles to authenticated;
grant select, update on public.schools to authenticated;
grant select, insert, update, delete on public.school_members to authenticated;
grant select, insert, update, delete on public.teachers to authenticated;
grant select, insert, update, delete on public.students to authenticated;
grant select, insert, update, delete on public.lessons to authenticated;
grant select, insert, update, delete on public.equipment to authenticated;
grant select, insert, update, delete on public.rentals to authenticated;
grant select, insert, update, delete on public.school_expenses to authenticated;
grant select, insert, update, delete on public.lesson_payouts to authenticated;
grant select, insert on public.audit_logs to authenticated;

grant execute on function public.create_school(text) to authenticated;
grant execute on function public.confirm_lesson_attendance(uuid) to authenticated;
