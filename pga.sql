set pagesize 100
set linesize 372
col action for a32
col module for a32
col machine for a32
col spid for a9
col status for a10
col sess for a16

select (select instance_name from v$instance) SID, to_char(sysdate, 'DD.MM.YYYY HH24:MI') from dual
/

select
   p.pid,
   p.spid,
   s.sid || '.' || s.serial# sess,
   round(p.PGA_USED_MEM/(1024*1024), 3) PGA_USED_MEM,
   round(p.PGA_ALLOC_MEM/(1024*1024), 3) PGA_ALLOC_MEM,
   round(p.PGA_MAX_MEM/(1024*1024), 3) PGA_MAX_MEM,
   round(p.PGA_FREEABLE_MEM/(1024*1024), 3) PGA_FREEABLE_MEM,
   round(sum(p.PGA_USED_MEM) over (order by pga_max_mem) / (1024*1024), 3) SUM_USED_MEM,
   round(sum(p.PGA_ALLOC_MEM) over (order by pga_max_mem) / (1024*1024), 3) SUM_ALLOC_MEM,
   round(sum(p.PGA_MAX_MEM) over (order by pga_max_mem) / (1024*1024), 3) SUM_MAX_MEM,
   round(sum(p.PGA_FREEABLE_MEM) over (order by pga_max_mem) / (1024*1024), 3) SUM_FREEABLE_MEM,
   s.action, s.module, s.machine, s.status
from v$process p, v$session s
where
  p.addr = s.paddr
  --and p.PGA_MAX_MEM/(1024*1024) > 25
order by PGA_USED_MEM
/

select (select instance_name from v$instance) SID, to_char(sysdate, 'DD.MM.YYYY HH24:MI') from dual
/
