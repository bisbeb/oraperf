-- Die Idee:
-- Startzeitpunkt: Alle aktiven Sessions + sql_ids ablegen
-- Endzeitpunkt  : Alle noch aktiven Sessions mit Start abgleichen
--                 von den noch (beim Endzeitpunkt) laufenden SQLs die Daten aus v$sqlarea berechnen:
--                 Section 1 (sorted by buffer_gets)
--                 + executions (t2.executions - t1.executions)
--                 + disk_reads (t2.disk_reads - t1.disk_reads)
--                 + buffer_gets (t2.buffer_gets - t2.buffer_gets)
--                 + direct_writes (t2.direct_writes - t1.direct_writes)
--                 Section 2 (sorted by cpu_time)
--                 + cpu_time (t2.cpu_time - t1.cpu_time)
--                 + user_io_wait_time (t2.user_io_wait_time - t1.user_io_wait_time)
--                 + concurrency_wait_time (t2.concurrency_wait_time - t1.concurrency_wait_time)
--                 + application_wait_time (t2.application_wait_time - t1.application_wait_time)

set serveroutput on;
set verify off;
set feedback off;
set linesize 512;

alter session set nls_date_format = 'DD.MM.YYYY HH24:MI:SS';
select (select instance_name from v$instance) SID, sysdate from dual;

prompt
prompt sampling for &1 (s)...
prompt

declare
    type sql_area_r is record(
      module varchar2(64), 
      action varchar2(64), 
      sql_id varchar2(64), 
      executions number, 
      disk_reads number, 
      direct_writes number, 
      buffer_gets number, 
      cpu_time number, 
      application_wait_time number, 
      concurrency_wait_time number, 
      user_io_wait_time number, 
      sql_text varchar2(48),
      total_wait_time number
    );

    type t_sql_area is table of sql_area_r;
  
    t1 t_sql_area;
    t2 t_sql_area;

    diff t_sql_area := t_sql_area();
    executions t_sql_area := t_sql_area();
    buffer_gets t_sql_area := t_sql_area();
    disk_reads t_sql_area := t_sql_area();
    direct_writes t_sql_area := t_sql_area();
    cpu_time t_sql_area := t_sql_area();
    concurrency_wait_time t_sql_area := t_sql_area();
    application_wait_time t_sql_area := t_sql_area();
    user_io_wait_time t_sql_area := t_sql_area();

    procedure prnt_table (t t_sql_area) is
      c_max integer := 20;
      i integer;
    begin
      if t.count = 0
      then
        dbms_output.put_line('<No SQLs found for this section>' || chr(10));
        return;
      end if;
      dbms_output.put_line(
        rpad('------------------------', 24) || '+' ||
        rpad('------------------------', 24) || '+' ||
        rpad('----------------', 16) || '+' ||
        rpad('-----', 5) || '+' ||
        rpad('-----', 5) || '+' ||
        rpad('-----', 5) || '+' ||
        rpad('-----', 5) || '+' ||
        rpad('-----', 5) || '+' ||
        rpad('-----', 5) || '+' ||
        rpad('-----', 5) || '+' ||
        rpad('-----', 5) || '+' ||
        '---------------------------------------------'
      );
      dbms_output.put_line(
        rpad('MODULE', 24) || '|' ||
        rpad('ACTION', 24) || '|' ||
        rpad('SQL_ID', 16) || '|' ||
        rpad('EXEC', 5) || '|' ||
        rpad('PHY R', 5) || '|' ||
        rpad('DIR W', 5) || '|' ||
        rpad('CR', 5) || '|' ||
        rpad('CPU', 5) || '|' ||
        rpad('UIO', 5) || '|' ||
        rpad('CONC', 5) || '|' ||
        rpad('APP', 5) || '|' ||
        'SQL_TEXT'
      );
      dbms_output.put_line(
        rpad('------------------------', 24) || '+' ||
        rpad('------------------------', 24) || '+' ||
        rpad('----------------', 16) || '+' ||
        rpad('-----', 5) || '+' ||
        rpad('-----', 5) || '+' ||
        rpad('-----', 5) || '+' ||
        rpad('-----', 5) || '+' ||
        rpad('-----', 5) || '+' ||
        rpad('-----', 5) || '+' ||
        rpad('-----', 5) || '+' ||
        rpad('-----', 5) || '+' ||
        '---------------------------------------------'
      );

      i := t.last;
      while ( c_max > 0 and i is not null)
      loop
        dbms_output.put_line(
          rpad(t(i).module, 24) || ' ' ||
          rpad(t(i).action, 24) || ' ' ||
          rpad(t(i).sql_id, 16) || ' ' ||
          rpad(t(i).executions, 5) || ' ' ||
          rpad(t(i).disk_reads, 5) || ' ' ||
          rpad(t(i).direct_writes, 5) || ' ' ||
          rpad(t(i).buffer_gets, 5) || ' ' ||
          rpad(t(i).cpu_time, 5) || ' ' ||
          rpad(t(i).user_io_wait_time, 5) || ' ' ||
          rpad(t(i).concurrency_wait_time, 5) || ' ' ||
          rpad(t(i).application_wait_time, 5) || ' ' ||
          t(i).sql_text
        );
        c_max := c_max - 1;
        i := t.prior(i);
      end loop;
      dbms_output.put_line(chr(10));
    end prnt_table;

    function sort_collection (r t_sql_area) return t_sql_area is
        sorted t_sql_area;
        temp sql_area_r;
        curr number;
        prev number;
    begin
        sorted := r;
        for i in 2..sorted.count
        loop
            curr := i;
            prev := i - 1;
            while sorted(prev).total_wait_time > sorted(curr).total_wait_time 
            loop
                temp := sorted(curr);
                sorted(curr) := sorted(prev);
                sorted(prev) := temp;
                curr := curr - 1;
                prev := prev - 1;
                if curr = 1 then
                    exit;
                end if;
            end loop;                
        end loop;
        return sorted;
    end sort_collection;

begin
    
    SELECT
       /*+
           OPT_PARAM('_optimizer_mjc_enabled','false')
           OPT_PARAM('_optimizer_cartesian_enabled','false')
       */
       nvl(stat.module, '<NONE>') module,
       nvl(stat.action, '<NONE>') action,
       stat.sql_id,
       max(stat.executions) executions,
       max(stat.disk_reads) disk_reads,
       max(stat.direct_writes) direct_writes,
       max(stat.buffer_gets) buffer_gets,
       max(stat.CPU_TIME) cpu_time,
       max(stat.APPLICATION_WAIT_TIME) application_wait_time,
       max(stat.CONCURRENCY_WAIT_TIME) concurrency_wait_time,
       max(stat.USER_IO_WAIT_TIME) user_io_wait_time,
       substr(trim(stat.sql_text),1,48) sql_text, 0
       BULK COLLECT INTO t1
    FROM v$session sess, v$sqlarea stat
    WHERE
       sess.sql_id = stat.sql_id
       and sess.sql_hash_value = stat.hash_value
       and SESS.SQL_ADDRESS = stat.address
       and sess.status in ( 'ACTIVE', 'KILLED' ) AND sess.TYPE <> 'BACKGROUND' AND sess.wait_class <> 'Idle'
    GROUP BY
       nvl(stat.module, '<NONE>'), nvl(stat.action, '<NONE>'), stat.sql_id, substr(trim(stat.sql_text),1,48);

    dbms_lock.sleep(&&1);

    SELECT
       /*+
           OPT_PARAM('_optimizer_mjc_enabled','false')
           OPT_PARAM('_optimizer_cartesian_enabled','false')
       */
       nvl(stat.module, '<NONE>') module,
       nvl(stat.action, '<NONE>') action,
       stat.sql_id,
       max(stat.executions) executions,
       max(stat.disk_reads) disk_reads,
       max(stat.direct_writes) direct_writes,
       max(stat.buffer_gets) buffer_gets,
       max(stat.CPU_TIME) cpu_time,
       max(stat.APPLICATION_WAIT_TIME) application_wait_time,
       max(stat.CONCURRENCY_WAIT_TIME) concurrency_wait_time,
       max(stat.USER_IO_WAIT_TIME) user_io_wait_time,
       substr(trim(stat.sql_text),1,48) sql_text, 0
       BULK COLLECT INTO t2
    FROM v$session sess, v$sqlarea stat
    WHERE
       sess.sql_id = stat.sql_id
       and sess.sql_hash_value = stat.hash_value
       and SESS.SQL_ADDRESS = stat.address
       and sess.status in ( 'ACTIVE', 'KILLED' ) AND sess.TYPE <> 'BACKGROUND' 
    GROUP BY
       nvl(stat.module, '<NONE>'), nvl(stat.action, '<NONE>'), stat.sql_id, substr(trim(stat.sql_text),1,48);

    -- calculate diff from t1 to t2
    for idx in 1 .. t2.count
    loop
        for jdx in 1 .. t1.count
        loop
          if (t1(jdx).sql_id = t2(idx).sql_id)
          then
            diff.extend;
            diff(diff.last).module 			:= t1(jdx).module;
            diff(diff.last).action 			:= t1(jdx).action;
            diff(diff.last).sql_id 			:= t1(jdx).sql_id;
            diff(diff.last).executions 			:= t2(idx).executions - t1(jdx).executions;
            diff(diff.last).disk_reads 			:= t2(idx).disk_reads - t1(jdx).disk_reads;
            diff(diff.last).direct_writes		:= t2(idx).direct_writes - t1(jdx).direct_writes;
            diff(diff.last).buffer_gets 		:= t2(idx).buffer_gets - t1(jdx).buffer_gets;
            diff(diff.last).cpu_time 			:= t2(idx).cpu_time - t1(jdx).cpu_time;
            diff(diff.last).application_wait_time 	:= t2(idx).application_wait_time - t1(jdx).application_wait_time;
            diff(diff.last).concurrency_wait_time 	:= t2(idx).concurrency_wait_time - t1(jdx).concurrency_wait_time;
            diff(diff.last).user_io_wait_time 		:= t2(idx).user_io_wait_time - t1(jdx).user_io_wait_time;
            diff(diff.last).sql_text 			:= t1(jdx).sql_text;

            diff(diff.last).total_wait_time		:= (diff(diff.last).cpu_time + diff(diff.last).application_wait_time + diff(diff.last).concurrency_wait_time + diff(diff.last).user_io_wait_time);
            exit;
          end if;
        end loop;
    end loop;
    
    if diff.count > 0
    then
      ---- 2.1 cpu time
      dbms_output.put_line('2.1 order by cpu_time:');
      cpu_time := sort_collection(diff);
      prnt_table( cpu_time );

    else
      dbms_output.put_line( 'no long running queries found within sample time: ' || &&1 );
    end if;
end;
/

select (select instance_name from v$instance) SID, sysdate from dual;

