-- 音源曲库与征集期选曲策略增量迁移
-- 旧歌曲保留；新投稿必须引用可用曲库条目。
begin;

create table if not exists public.song_catalog (
  id uuid primary key default gen_random_uuid(),
  title text not null check (length(trim(title)) between 1 and 80),
  artist text not null check (length(trim(artist)) between 1 and 80),
  title_lower text generated always as (lower(trim(title))) stored,
  artist_lower text generated always as (lower(trim(artist))) stored,
  source_url text,
  duration_seconds integer check (duration_seconds is null or duration_seconds between 1 and 3600),
  is_available boolean not null default false,
  is_active boolean not null default true,
  notes text not null default '',
  created_by text,
  updated_by text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(title_lower, artist_lower)
);

create table if not exists public.period_catalog_policies (
  period_id uuid primary key references public.playlist_periods(id) on delete restrict,
  whitelist_enabled boolean not null default false,
  allowed_catalog_ids uuid[] not null default '{}',
  updated_by text,
  updated_at timestamptz not null default now()
);

alter table public.songs add column if not exists catalog_id uuid;
create index if not exists song_catalog_search_idx on public.song_catalog(title_lower, artist_lower);
create index if not exists songs_catalog_id_idx on public.songs(catalog_id);

alter table public.song_catalog enable row level security;
alter table public.period_catalog_policies enable row level security;

drop policy if exists song_catalog_public_read on public.song_catalog;
drop policy if exists song_catalog_admin_read on public.song_catalog;
drop policy if exists period_catalog_policy_admin_read on public.period_catalog_policies;

create policy song_catalog_public_read on public.song_catalog
  for select to anon, authenticated using (is_active and is_available);
create policy song_catalog_admin_read on public.song_catalog
  for select to authenticated using (public.is_current_user_admin());
create policy period_catalog_policy_admin_read on public.period_catalog_policies
  for select to authenticated using (public.is_current_user_admin());

create or replace function public.get_song_catalog(p_period_id uuid)
returns table(id uuid,title text,artist text,duration_seconds integer,notes text)
language sql security definer set search_path=public as $catalog$
  select c.id,c.title,c.artist,c.duration_seconds,c.notes
  from public.song_catalog c
  left join public.period_catalog_policies policy on policy.period_id=p_period_id
  where c.is_active and c.is_available
    and (coalesce(policy.whitelist_enabled,false)=false
      or c.id = any(coalesce(policy.allowed_catalog_ids,'{}'::uuid[])))
  order by c.title_lower,c.artist_lower;
$catalog$;
revoke all on function public.get_song_catalog(uuid) from public;
grant execute on function public.get_song_catalog(uuid) to anon, authenticated;

create or replace function public.admin_upsert_song_catalog(
  p_id uuid default null,
  p_title text default '',
  p_artist text default '',
  p_source_url text default null,
  p_duration_seconds integer default null,
  p_is_available boolean default false,
  p_is_active boolean default true,
  p_notes text default ''
)
returns uuid language plpgsql security definer set search_path=public as $admin_catalog$
declare result_id uuid;
begin
  if public.is_current_user_admin() is not true then raise exception 'Admin permission required.'; end if;
  if length(trim(coalesce(p_title,''))) not between 1 and 80 or length(trim(coalesce(p_artist,''))) not between 1 and 80 then
    raise exception '歌名和歌手须为 1–80 字。';
  end if;
  if p_duration_seconds is not null and p_duration_seconds not between 1 and 3600 then
    raise exception '歌曲时长必须在 1–3600 秒之间。';
  end if;
  if p_id is null then
    insert into public.song_catalog(title,artist,source_url,duration_seconds,is_available,is_active,notes,created_by,updated_by)
      values(trim(p_title),trim(p_artist),nullif(trim(coalesce(p_source_url,'')),''),p_duration_seconds,p_is_available,p_is_active,trim(coalesce(p_notes,'')),auth.uid()::text,auth.uid()::text)
      returning id into result_id;
  else
    update public.song_catalog set title=trim(p_title),artist=trim(p_artist),source_url=nullif(trim(coalesce(p_source_url,'')),''),duration_seconds=p_duration_seconds,
      is_available=p_is_available,is_active=p_is_active,notes=trim(coalesce(p_notes,'')),updated_by=auth.uid()::text,updated_at=clock_timestamp()
      where id=p_id returning id into result_id;
    if result_id is null then raise exception '曲库条目不存在。'; end if;
  end if;
  return result_id;
end;
$admin_catalog$;
revoke all on function public.admin_upsert_song_catalog(uuid,text,text,text,integer,boolean,boolean,text) from public,anon,authenticated;
grant execute on function public.admin_upsert_song_catalog(uuid,text,text,text,integer,boolean,boolean,text) to authenticated;

create or replace function public.admin_set_period_catalog_policy(p_period_id uuid,p_whitelist_enabled boolean,p_allowed_catalog_ids uuid[] default '{}')
returns void language plpgsql security definer set search_path=public as $policy$
begin
  if public.is_current_user_admin() is not true then raise exception 'Admin permission required.'; end if;
  if not exists(select 1 from public.playlist_periods where id=p_period_id) then raise exception '征集期不存在。'; end if;
  insert into public.period_catalog_policies(period_id,whitelist_enabled,allowed_catalog_ids,updated_by,updated_at)
    values(p_period_id,p_whitelist_enabled,coalesce(p_allowed_catalog_ids,'{}'),auth.uid()::text,clock_timestamp())
    on conflict(period_id) do update set whitelist_enabled=excluded.whitelist_enabled,allowed_catalog_ids=excluded.allowed_catalog_ids,updated_by=excluded.updated_by,updated_at=excluded.updated_at;
end;
$policy$;
revoke all on function public.admin_set_period_catalog_policy(uuid,boolean,uuid[]) from public,anon,authenticated;
grant execute on function public.admin_set_period_catalog_policy(uuid,boolean,uuid[]) to authenticated;

drop function if exists public.submit_song_from_catalog(uuid,text,text);
create function public.submit_song_from_catalog(p_catalog_id uuid,p_playlist_date text,p_voter_cookie text)
returns table(id uuid,title text,artist text,playlist_date text,likes_count integer,created_at timestamptz,error_code text,error_message text)
language plpgsql security definer set search_path=public as $submit_catalog$
declare identity text; target uuid; period_record public.playlist_periods%rowtype; catalog_record public.song_catalog%rowtype; maximum integer;
begin
  perform public.consume_api_attempt('submission',p_playlist_date,p_voter_cookie);
  begin
    identity=public.assert_valid_voter_cookie(p_voter_cookie);
    target=p_playlist_date::uuid;
    select * into period_record from public.playlist_periods where id=target for share;
    if not found or period_record.status<>'active' or clock_timestamp() not between period_record.starts_at and period_record.ends_at then raise exception '征集已结束或尚未开始，请刷新页面。'; end if;
    select c.* into catalog_record from public.song_catalog c
      left join public.period_catalog_policies policy on policy.period_id=target
      where c.id=p_catalog_id and c.is_active and c.is_available
        and (coalesce(policy.whitelist_enabled,false)=false or c.id=any(coalesce(policy.allowed_catalog_ids,'{}'::uuid[])))
      for share;
    if not found then raise exception '这首歌当前没有可用音源，或不在本期可选范围内。'; end if;
    perform pg_advisory_xact_lock(hashtextextended('actor:'||target::text||':'||identity,0));
    select submission_cookie_per_period into maximum from public.security_settings where id=true;
    if (select count(*) from public.songs s where s.period_id=target and s.created_by='cookie:'||md5(identity))>=maximum then raise exception '本浏览器已达到本期投稿数量上限。'; end if;
    return query insert into public.songs as s(title,artist,title_lower,artist_lower,playlist_date,period_id,created_by,catalog_id)
      values(catalog_record.title,catalog_record.artist,catalog_record.title_lower,catalog_record.artist_lower,target::text,target,'cookie:'||md5(identity),p_catalog_id)
      returning s.id,s.title,s.artist,s.playlist_date,s.likes_count,s.created_at,null::text,null::text;
  exception when unique_violation then
    return query select null::uuid,null::text,null::text,null::text,0,null::timestamptz,'23505'::text,'本期已有同名、同歌手的歌曲。'::text;
  when others then
    return query select null::uuid,null::text,null::text,null::text,0,null::timestamptz,sqlstate,case when sqlstate in('P0001','23503','23514','22P02') then sqlerrm else '投稿失败，请稍后重试。' end;
  end;
end;
$submit_catalog$;
revoke all on function public.submit_song_from_catalog(uuid,text,text) from public;
grant execute on function public.submit_song_from_catalog(uuid,text,text) to anon,authenticated;
revoke all on function public.submit_song(text,text,text,text) from anon,authenticated;

notify pgrst, 'reload schema';
commit;
