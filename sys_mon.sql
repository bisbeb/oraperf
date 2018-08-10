set serveroutput on;
set verify off;
set feedback off;
set linesize 128

alter session set nls_date_format = 'DD.MM.YYYY HH24:MI:SS';
select (select instance_name from v$instance) SID, sysdate from dual;

prompt
prompt sampling for &1 (s)...
prompt

declare
    type sys_event_r is record(event varchar2(64), wait_class varchar2(64), time_waited number, total_waits number);
    type sys_cpu_r is record(stat_name varchar2(64), val1 number);
    type os_cpu_r is record(stat_name varchar2(64), value number);
    type sys_cpu is table of sys_cpu_r;
    type os_cpu is table of os_cpu_r;
    type sys_event is table of sys_event_r;
    r1 sys_event;
    r2 sys_event;
    diff sys_event := sys_event ();
    cpu1 sys_cpu;
    cpu2 sys_cpu;
    os1 os_cpu;
    os2 os_cpu; 
    total_waited number := 0;
    total_waits number := 0;
    total_cpu number := 0;
    total_bg_cpu number := 0;
    sess_cnt_start number := 0;
    sess_cnt_end number := 0;
    cpu_count number := 0;
    cpu_idle number := 0;
    cpu_user number := 0;
    cpu_sys number := 0;

    function insertion_sort (r sys_event) return sys_event is
        sorted sys_event;
        temp sys_event_r;
        curr number;
        prev number;
    begin
        sorted := r;
        for i in 2..sorted.count
        loop
            curr := i;
            prev := i - 1;
            while sorted(prev).time_waited > sorted(curr).time_waited 
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
    select stat_name, value bulk collect into os1 from v$osstat where stat_name in ( 'IDLE_TIME', 'BUSY_TIME', 'USER_TIME', 'SYS_TIME' ) order by stat_name;
    select stat_name, (sum(value)/1000000) bulk collect into cpu1 from v$sys_time_model where stat_name in ('DB CPU', 'background cpu time') group by stat_name order by stat_name;
    select event, wait_class, time_waited / 100, total_waits bulk collect into r1 from v$system_event where time_waited > 1000 and wait_class not in ('Idle') order by wait_class, event;
    select count(*) into sess_cnt_start from v$session where status = 'ACTIVE';
    dbms_lock.sleep(&&1);
    select stat_name, value bulk collect into os2 from v$osstat where stat_name in ( 'IDLE_TIME', 'BUSY_TIME', 'USER_TIME', 'SYS_TIME' ) order by stat_name;
    select stat_name, (sum(value)/1000000) bulk collect into cpu2 from v$sys_time_model where stat_name in ('DB CPU', 'background cpu time') group by stat_name order by stat_name;
    select event, wait_class, time_waited / 100, total_waits bulk collect into r2 from v$system_event where time_waited > 1000 and wait_class not in ('Idle') order by wait_class, event;
    select count(*) into sess_cnt_end from v$session where status = 'ACTIVE';
    for idx in 1 .. r1.count
    loop
        for jdx in 1 .. r2.count
        loop
            if r1(idx).event = r2(jdx).event
            then
              if (r2(jdx).time_waited - r1(idx).time_waited > 0) or (r2(jdx).total_waits - r1(idx).total_waits > 0)
              then
                diff.extend;
                diff(diff.last).wait_class := r1(idx).wait_class;
                diff(diff.last).event := r1(idx).event;
                diff(diff.last).time_waited := r2(jdx).time_waited - r1(idx).time_waited;
                diff(diff.last).total_waits := r2(jdx).total_waits - r1(idx).total_waits;
                total_waited := total_waited + (r2(jdx).time_waited - r1(idx).time_waited);
                total_waits := total_waits + (r2(jdx).total_waits - r1(idx).total_waits);
              end if;
              exit;
            end if;
        end loop;
    end loop;
    
    total_cpu := cpu2(1).val1 - cpu1(1).val1;
    total_bg_cpu := cpu2(2).val1 - cpu1(2).val1;
    total_waited := total_waited + total_cpu;

    dbms_output.put_line(rpad('WAIT CLASS', 16) || ' ' || rpad('EVENT', 32) || ' ' || lpad('WAITED', 6) || ' ' || lpad('WAITS', 6) || ' ' || lpad('PTC', 12) || ' ' || lpad('AVG WAIT (s)', 12));
    dbms_output.put_line(rpad('-', 16, '-') || ' ' || rpad('-', 32, '-') || ' ' || lpad('-', 6, '-') || ' ' || lpad('-', 6, '-') || ' ' || lpad('-', 12, '-') || ' ' || lpad('-', 12, '-'));

    diff := insertion_sort(diff);
    for idx in 1 .. diff.count
    loop
      dbms_output.put_line(
        rpad(diff(idx).wait_class, 16) || ' ' || 
        rpad(diff(idx).event, 32) || ' ' || 
        lpad(diff(idx).time_waited, 6) || ' ' || 
        lpad(diff(idx).total_waits, 6) || ' ' ||
        lpad(round(100*(diff(idx).time_waited/total_waited), 3), 12) || ' ' ||
        lpad(round((diff(idx).time_waited/total_waits), 3), 12)
      );
    end loop;

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
    dbms_output.put_line('DB CPU                   : ' || round(total_cpu, 3) || ' (' || round(100*(total_cpu/total_waited), 2) || '%)');
    dbms_output.put_line('Background CPU           : ' || round(total_bg_cpu, 3) || ' (' || round(100*(total_bg_cpu/total_waited), 2) || '%)');
    dbms_output.put_line('Total waited (s)         : ' || round(total_waited - total_cpu, 3) || ' (' || round(100*((total_waited - total_cpu)/total_waited), 2) || '%)');
    dbms_output.put_line('Total waited + DB CPU (s): ' || round(total_waited, 3));
    dbms_output.put_line('Total waits              : ' || total_waits);
    dbms_output.put_line(' ');
    dbms_output.put_line('# sessions start         : ' || sess_cnt_start);
    dbms_output.put_line('# sessions end           : ' || sess_cnt_end);
    dbms_output.put_line('-------------------------------------------------');
    dbms_output.put_line('OS CPU Idle: ' || round(100*(cpu_idle/(cpu_idle+cpu_user+cpu_sys)), 2));
    dbms_output.put_line('OS CPU User: ' || round(100*(cpu_user/(cpu_idle+cpu_user+cpu_sys)), 2));
    dbms_output.put_line('OS CPU Sys : ' || round(100*(cpu_sys /(cpu_idle+cpu_user+cpu_sys)), 2));
    dbms_output.put_line('=================================================');
end;
/

select (select instance_name from v$instance) SID, sysdate from dual;

