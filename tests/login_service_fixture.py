#!/usr/bin/env python3
"""Exercise the built Linux service + PAM helper in a disposable container."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

if os.getuid()!=0 or not Path('/.dockerenv').exists():
    raise SystemExit('Requires a disposable Linux container.')
service,helper=sys.argv[1:]
uid=int(subprocess.check_output(['id','-u','fixture']))
gid=int(subprocess.check_output(['id','-g','fixture']))
shutil.copyfile(helper,'/usr/local/bin/illogical-login')
os.chmod('/usr/local/bin/illogical-login',0o4755)
with tempfile.TemporaryDirectory(prefix='illogical-pam-service-',dir='/tmp') as state:
    os.chown(state,uid,gid)
    base=['runuser','-u','fixture','--','env','ILLOGICAL_HOME='+state,'SHELL=/bin/sh',service]
    log=open('/out/login-service.log','w')
    daemon=subprocess.Popen(base+['serve','--login-helper','/usr/local/bin/illogical-login'],stdout=log,stderr=log)
    def cli(*args): return subprocess.check_output(base+list(args),text=True,timeout=10)
    try:
        deadline=time.monotonic()+10
        while not Path(state,'daemon.sock').exists() and time.monotonic()<deadline:time.sleep(.01)
        created=json.loads(cli('new','pam-e2e','--keep-open','--','/bin/sh','-c','printf "UID="; id -u; printf "LOGINUID="; cat /proc/self/loginuid; printf "\nNOFILE="; ulimit -n; printf READY; exec sleep 30'))
        first=json.loads(cli('ls'))['state']['blocks'][0]
        block=first['id'];pid=first['pid']
        deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            text=cli('capture','--block',block)
            if 'READY' in text:break
            time.sleep(.02)
        assert 'UID='+str(uid) in text and 'LOGINUID='+str(uid) in text and 'NOFILE=128' in text,text
        second=json.loads(cli('ls'))['state']['blocks'][0]
        assert second['pid']==pid and 'exitCode' not in second,second
        process=json.loads(cli('block','process','--block',block))['process']
        assert process['foreground']['uid']==uid,process
        cli('send-key','ctrl-c','--block',block)
        deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            after=json.loads(cli('ls'))['state']['blocks'][0]
            if 'exitCode' in after:break
            time.sleep(.02)
        assert after.get('exitCode')==130,after
        socket_mode=Path(state,'daemon.sock').stat().st_mode&0o777
        assert socket_mode==0o600,socket_mode
        cli('server','stop')
        daemon.wait(timeout=5)
        print(json.dumps({'linux_service_pam':True,'same_pid_after_cli_disconnect':True,'foreground_uid':uid,'pam_loginuid':True,'pam_limits':True,'protocol_ctrl_c_exit':130,'private_socket_mode':oct(socket_mode),'state_directory_mode':oct(Path(state).stat().st_mode&0o777)}))
    finally:
        if daemon.poll() is None:
            daemon.terminate()
            try:daemon.wait(timeout=5)
            except subprocess.TimeoutExpired:daemon.kill();daemon.wait()
        log.close()
