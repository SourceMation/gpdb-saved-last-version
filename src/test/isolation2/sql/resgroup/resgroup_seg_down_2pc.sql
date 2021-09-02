-- This test performs segment reconfiguration when "alter resource group" is executed in the two phase commit.
-- The steps are, when run "alter resource group", before QD broadcasts commit prepared command to QEs(the 
-- second phase of 2PC), we trigger an error and cause one primary segment down. 
-- The expectation is "alter resource group" can run successfully since the mirror segment is UP. 
-- After recover the segment, there is no error or blocking.

-- set these values purely to cut down test time
-- start_ignore
! gpconfig -c gp_fts_probe_timeout -v 2;
! gpconfig -c gp_fts_probe_interval -v '10s';
! gpstop -ari;
-- end_ignore

CREATE EXTENSION IF NOT EXISTS gp_inject_fault;

-- Helper function
CREATE or REPLACE FUNCTION wait_until_segments_are_down(num_segs int)
RETURNS bool AS
$$
declare
retries int; /* in func */
begin /* in func */
  retries := 1200; /* in func */
  loop /* in func */
    if (select count(*) = num_segs from gp_segment_configuration where status = 'd') then /* in func */
      return true; /* in func */
    end if; /* in func */
    if retries <= 0 then /* in func */
      return false; /* in func */
    end if; /* in func */
    perform pg_sleep(0.1); /* in func */
    retries := retries - 1; /* in func */
  end loop; /* in func */
end; /* in func */
$$ language plpgsql;

create or replace function wait_until_all_segments_synchronized() returns text as $$
begin
        for i in 1..1200 loop
                if (select count(*) = 0 from gp_segment_configuration where content != -1 and mode != 's') then
                        return 'OK'; /* in func */
                end if; /* in func */
                perform pg_sleep(0.1); /* in func */
        end loop; /* in func */
        return 'Fail'; /* in func */
end; /* in func */
$$ language plpgsql;

1:create resource group rgroup_seg_down with (CPU_RATE_LIMIT=35, MEMORY_LIMIT=35, CONCURRENCY=10);

-- inject an error in function dtm_broadcast_commit_prepared, that is before QD broadcasts commit prepared command to QEs
2:select gp_inject_fault_new( 'dtm_broadcast_commit_prepared', 'suspend', dbid) from gp_segment_configuration where content=-1 and role='p';
-- this session will pend here since the above injected fault
1&:alter resource group rgroup_seg_down set CONCURRENCY 20;
-- this injected fault can make dispatcher think the primary is down
2:select gp_inject_fault_new('segment_probe_response', 'sleep', '', '', '', 1, -1, 600, dbid) from gp_segment_configuration where content=0 and preferred_role='p';
2:select wait_until_segments_are_down(1);
-- make sure one primary segment is down.
2:select status = 'd' from gp_segment_configuration where content = 0 and role = 'm';
-- reset the injected fault on QD and the "alter resource group" in session1 can continue
2:SELECT gp_inject_fault_new( 'dtm_broadcast_commit_prepared', 'reset',  dbid) from gp_segment_configuration where content=-1 and role='p';
1<:
-- make sure "alter resource group" has taken effect.
1:select concurrency from gp_toolkit.gp_resgroup_config where groupname = 'rgroup_seg_down';
2q:

-- start_ignore
! gprecoverseg -a;
! gprecoverseg -ar;
-- end_ignore

-- loop while segments come in sync
1:select wait_until_all_segments_synchronized();

-- verify no segment is down after recovery
1:select count(*) from gp_segment_configuration where status = 'd';

-- verify resource group 
1:select concurrency from gp_toolkit.gp_resgroup_config where groupname = 'rgroup_seg_down';
1:drop resource group rgroup_seg_down;
1q:

-- start_ignore
! gpconfig -r gp_fts_probe_timeout;
! gpconfig -r gp_fts_probe_interval;
! gpstop -rai;
-- end_ignore