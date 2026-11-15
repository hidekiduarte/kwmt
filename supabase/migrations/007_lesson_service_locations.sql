-- KWMT migration 007: vincular aulas aos locais de atendimento
-- A escola continua sendo o tenant. Localizações são contextos operacionais
-- compartilhados: não possuem alunos, equipe ou financeiro independentes.
-- Aplicar somente após revisão; esta migration não é executada automaticamente.

alter table public.lessons
  add column if not exists location_id uuid;

do $$
begin
  if not exists (
    select 1 from pg_catalog.pg_constraint
    where conrelid = 'public.lessons'::regclass
      and conname = 'lessons_school_location_fk'
  ) then
    alter table public.lessons
      add constraint lessons_school_location_fk
      foreign key (school_id, location_id)
      references public.school_locations(school_id, id);
  end if;
end;
$$;

create index if not exists idx_lessons_school_location_start
  on public.lessons(school_id, location_id, starts_at);

-- Aulas novas precisam indicar um local ativo pertencente à mesma escola.
-- A FK composta impede associação cruzada entre escolas; a validação abaixo
-- impede uso de local desativado. Aulas antigas podem continuar com NULL.
create or replace function public.validate_lesson_location()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Depois da conclusão, o local integra o histórico operacional da aula.
  if tg_op = 'UPDATE'
     and old.status = 'completed'
     and (new.location_id is distinct from old.location_id
          or new.school_id is distinct from old.school_id) then
    raise exception 'Completed lesson location cannot be changed';
  end if;

  if tg_op = 'INSERT' and new.location_id is null then
    raise exception 'An active service location is required for new lessons';
  end if;

  if new.location_id is not null and not exists (
    select 1
    from public.school_locations l
    where l.id = new.location_id
      and l.school_id = new.school_id
      and l.active = true
  ) then
    raise exception 'Service location is inactive or does not belong to this school';
  end if;

  return new;
end;
$$;

revoke all on function public.validate_lesson_location() from public, anon, authenticated;

drop trigger if exists trg_validate_lesson_location on public.lessons;
create trigger trg_validate_lesson_location
before insert or update of school_id, location_id
on public.lessons
for each row execute function public.validate_lesson_location();

comment on column public.lessons.location_id is
  'Local de atendimento da aula. Escola permanece como tenant; dados operacionais e financeiros são compartilhados.';
