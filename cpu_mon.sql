set serveroutput on;
set verify off;
set feedback off;

alter session set nls_date_format = 'DD.MM.YYYY HH24:MI:SS';
select (select instance_name from v$instance) SID, sysdate from dual;

prompt
prompt sampling for &1 (s)...
prompt

declare
    cpu_count number := 0;
    sess1 number := 0;
    sess2 number := 0;

    -- os cpu
    type os_cpu_r is record(stat_name varchar2(64), value number);
    type os_cpu is table of os_cpu_r;
    os1 os_cpu;
    os2 os_cpu;
    cpu_idle number := 0;
    cpu_user number := 0;
    cpu_sys number := 0;
    
    -- sys time model
    type sys_cpu_r is record(stat_name varchar2(64), val1 number);
    type sys_cpu is table of sys_cpu_r;
    cpu1 sys_cpu;
    cpu2 sys_cpu;
    diff sys_cpu := sys_cpu();

    -- db cpu analysis / v$sysstat
    t0_cpu_all_s number := 0;
    t0_cpu_parse_s number := 0;
    t0_recur_s number := 0;
    t1_cpu_all_s number := 0;
    t1_cpu_parse_s number := 0;
    t1_recur_s number := 0;

    function insertion_sort (r sys_cpu) return sys_cpu is
        sorted sys_cpu;
        temp sys_cpu_r;
        curr number;
        prev number;
    begin
        sorted := r;
        for i in 2..sorted.count
        loop
            curr := i;
            prev := i - 1;
            while sorted(prev).val1 > sorted(curr).val1
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
    end insertion_sort;

begin
    select display_value into cpu_count from v$parameter where name = 'cpu_count';
    -- count sessions
    select count(*) into sess1 from v$session where status = 'ACTIVE';
    -- os cpu stats
    select stat_name, value bulk collect into os1 from v$osstat where stat_name in ( 'IDLE_TIME', 'BUSY_TIME', 'USER_TIME', 'SYS_TIME' ) order by stat_name;
    -- v$sysstat
    select value/100 into t0_cpu_all_s from v$sysstat where name = 'CPU used by this session';
    select value/100 into t0_cpu_parse_s from v$sysstat where name = 'parse time cpu';
    select value/100 into t0_recur_s from v$sysstat where name = 'recursive cpu usage';
    -- time model stats
    select stat_name, (sum(value)/1000000) bulk collect into cpu1 from v$sys_time_model group by stat_name order by stat_name;

    -- start: sleep interval
    dbms_lock.sleep(&&1);
    -- end: sleep interval

    -- os cpu stats
    select stat_name, value bulk collect into os2 from v$osstat where stat_name in ( 'IDLE_TIME', 'BUSY_TIME', 'USER_TIME', 'SYS_TIME' ) order by stat_name;
    -- v$sysstat
    select value/100 into t1_cpu_all_s from v$sysstat where name = 'CPU used by this session';
    select value/100 into t1_cpu_parse_s from v$sysstat where name = 'parse time cpu';
    select value/100 into t1_recur_s from v$sysstat where name = 'recursive cpu usage';
    -- time model stats
    select stat_name, (sum(value)/1000000) bulk collect into cpu2 from v$sys_time_model group by stat_name order by stat_name;
    -- count sessions
    select count(*) into sess2 from v$session where status = 'ACTIVE';

    -- diff cpu1 stats from v$sys_time_model
    for idx in 1..cpu1.count
    loop
      for jdx in 1..cpu2.count
      loop
        if cpu1(idx).stat_name = cpu2(jdx).stat_name
        then
          diff.extend;
          diff(diff.last).stat_name := cpu1(idx).stat_name;
          diff(diff.last).val1 := round(cpu2(jdx).val1 - cpu1(idx).val1, 3);
        end if;
      end loop;
    end loop;
    diff := insertion_sort(diff);

    -- os cpu stats
    for idx in 1 .. os1.count
    loop
      for jdx in 1 .. os2.count
      loop
        if os1(idx).stat_name = os2(jdx).stat_name
        then
          if os1(idx).stat_name = 'IDLE_TIME'
          then
            cpu_idle := os2(jdx).value - os1(idx).value;
          end if;
          if os1(idx).stat_name = 'USER_TIME'
          then
            cpu_user := os2(jdx).value - os1(idx).value;
          end if;
          if os1(idx).stat_name = 'SYS_TIME'
          then
            cpu_sys := os2(jdx).value - os1(idx).value;
          end if;
          exit;
        end if;
      end loop;
    end loop;


    dbms_output.put_line(' ');
    dbms_output.put_line('=================================================');
    dbms_output.put_line('# host (v)CPUs           : ' || cpu_count);
    dbms_output.put_line('Max. CPU Time (s)        : ' || (cpu_count * &&1));
    dbms_output.put_line('-------------------------------------------------');
    dbms_output.put_line('# active sessions (start): ' || sess1);
    dbms_output.put_line('# active sessions (end)  : ' || sess2);
    dbms_output.put_line('-------------------------------------------------');
    dbms_output.put_line('Total CPU                : ' || (t1_cpu_all_s - t0_cpu_all_s));
    dbms_output.put_line('Recursive CPU            : ' || (t1_recur_s - t0_recur_s));
    dbms_output.put_line('Parse CPU                : ' || (t1_cpu_parse_s - t0_cpu_parse_s));
    dbms_output.put_line('-------------------------------------------------');
    dbms_output.put_line('Instance utilization     : ' || round(((t1_cpu_all_s - t0_cpu_all_s) / (cpu_count * &&1))*100, 3) || '%');
    dbms_output.put_line('OS CPU User              : ' || round(100*(cpu_user/(cpu_idle+cpu_user+cpu_sys)), 3) || '%');
    dbms_output.put_line('OS CPU Sys               : ' || round(100*(cpu_sys /(cpu_idle+cpu_user+cpu_sys)), 3) || '%');
    dbms_output.put_line('OS CPU Idle              : ' || round(100*(cpu_idle/(cpu_idle+cpu_user+cpu_sys)), 3) || '%');
    dbms_output.put_line('-------------------------------------------------');
    for idx in 1..diff.count
    loop
      dbms_output.put_line('....' || rpad(diff(idx).stat_name, 64) || ' : ' || diff(idx).val1);
    end loop;
    dbms_output.put_line('=================================================');
end;
/

select (select instance_name from v$instance) SID, sysdate from dual;

