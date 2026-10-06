create or replace function public.allocate_e2ee_key_version(p_conversation_id uuid)
returns integer language plpgsql security definer set search_path = ''
as $function$
declare actor uuid := auth.uid(); current_value integer; allocated bigint;
begin
 if actor is null then raise exception 'Not authenticated' using errcode='42501'; end if;
 if not exists(select 1 from public.conversation_members cm where cm.conversation_id=p_conversation_id and cm.user_id=actor)
 then raise exception 'Not a conversation member' using errcode='42501'; end if;
 insert into public.e2ee_conversation_key_versions(conversation_id,current_version) values(p_conversation_id,1)
 on conflict(conversation_id) do nothing;
 select current_version into current_value from public.e2ee_conversation_key_versions where conversation_id=p_conversation_id for update;
 select greatest(current_value::bigint,coalesce(max(k.key_version),1)::bigint,1::bigint)+1 into allocated
 from public.e2ee_conversation_keys k where k.conversation_id=p_conversation_id;
 if allocated>2147483647 then raise exception 'E2EE key version limit reached'; end if;
 update public.e2ee_conversation_key_versions set current_version=allocated::integer,updated_at=now() where conversation_id=p_conversation_id;
 return allocated::integer;
end $function$;
revoke all on function public.allocate_e2ee_key_version(uuid) from public,anon;
grant execute on function public.allocate_e2ee_key_version(uuid) to authenticated;
