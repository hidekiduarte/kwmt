-- KWMT migration 008: relatório financeiro por período e local de atendimento
-- A escola permanece como tenant; locais são apenas agrupamentos operacionais.
-- Esta migration apenas cria a RPC. Não executa consultas nem altera dados existentes.

create or replace function public.get_school_location_financial_report(
    p_school_id uuid,
    p_start_date timestamptz,
    p_end_date timestamptz
)
returns table (
    location_id uuid,
    location_name text,
    total_lessons bigint,
    total_gross_revenue numeric,
    total_teacher_payouts numeric,
    total_school_net numeric
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
    -- SECURITY DEFINER não deve depender do RLS para autorizar o acesso.
    -- A função valida explicitamente o vínculo ativo de proprietário.
    if auth.uid() is null then
        raise exception 'Autenticação necessária.';
    end if;

    if not public.is_school_owner(p_school_id) then
        raise exception 'Acesso negado ao relatório financeiro.';
    end if;

    if p_start_date is null
       or p_end_date is null
       or p_start_date >= p_end_date then
        raise exception 'Informe um período válido.';
    end if;

    return query
    select
        l.location_id,
        coalesce(loc.location_name, 'Local não informado')::text,
        count(l.id)::bigint,
        coalesce(sum(f.gross_amount), 0)::numeric,
        coalesce(sum(f.teacher_payout_amount), 0)::numeric,
        coalesce(
            sum(f.gross_amount - f.teacher_payout_amount),
            0
        )::numeric
    from public.lessons l
    left join public.school_locations loc
        on loc.school_id = l.school_id
       and loc.id = l.location_id
    left join public.lesson_financial_records f
        on f.school_id = l.school_id
       and f.lesson_id = l.id
    where l.school_id = p_school_id
      and l.status = 'completed'
      and l.starts_at >= p_start_date
      and l.starts_at < p_end_date
    group by
        l.location_id,
        loc.location_name;
end;
$$;

-- A RPC é destinada exclusivamente a usuários autenticados.
revoke all on function public.get_school_location_financial_report(
    uuid, timestamptz, timestamptz
) from public, anon;

grant execute on function public.get_school_location_financial_report(
    uuid, timestamptz, timestamptz
) to authenticated;

comment on function public.get_school_location_financial_report(
    uuid, timestamptz, timestamptz
) is
    'Relatório financeiro de aulas concluídas por local e período. O líquido é calculado como bruto menos repasse; aulas legadas sem local permanecem no grupo Local não informado.';
