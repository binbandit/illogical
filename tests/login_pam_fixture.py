#!/usr/bin/env python3
"""Run only inside a disposable root-owned Linux test container."""
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import sys
import termios
import time

if os.getuid() != 0 or not Path('/.dockerenv').exists():
    raise SystemExit('This fixture requires a disposable Linux container; never run on a host.')
subprocess.run(['useradd','--create-home','--shell','/bin/sh','fixture'],check=True)
subprocess.run(['cp',sys.argv[1] if len(sys.argv)>1 else '/out/illogical-login','/usr/local/bin/illogical-login'],check=True)
os.chmod('/usr/local/bin/illogical-login',0o4755)
uid=int(subprocess.check_output(['id','-u','fixture']))
gid=int(subprocess.check_output(['id','-g','fixture']))
Path('/usr/local/bin/pam-audit').write_text('#!/bin/sh\nprintf "%s:%s\\n" "$PAM_TYPE" "$PAM_USER" >> /tmp/pam-audit\n')
os.chmod('/usr/local/bin/pam-audit',0o755)
policy='auth required pam_permit.so\naccount required pam_permit.so\nsession required pam_exec.so /usr/local/bin/pam-audit\n'
Path('/etc/pam.d/illogical').write_text(policy)

def run(command,interrupt=False,terminate=False,terminal_owner=None,during_open=False):
    master,slave=pty.openpty()
    os.fchown(slave,uid if terminal_owner is None else terminal_owner,gid)
    audit_before=Path("/tmp/pam-audit").read_text().count("open_session") if Path("/tmp/pam-audit").exists() else 0
    child=os.fork()
    if child==0:
        os.close(master)
        os.setsid();fcntl.ioctl(slave,termios.TIOCSCTTY,0)
        for fd in range(3):os.dup2(slave,fd)
        if slave>2:os.close(slave)
        os.setgroups([]);os.setgid(gid);os.setuid(uid)
        os.environ['HOME']='/root/forged';os.environ['USER']='forged';os.environ['PYTHONPATH']='/malicious'
        os.execv('/usr/local/bin/illogical-login',['illogical-login','--','/bin/sh','sh','-c',command])
    os.close(slave); output=b''; started=time.monotonic(); status=None;sent=False
    try:
        while time.monotonic()-started<5:
            ready,_,_=select.select([master],[],[],0.05)
            if ready:
                try:output+=os.read(master,65536)
                except OSError:pass
            open_started = during_open and Path('/tmp/pam-audit').exists() and Path('/tmp/pam-audit').read_text().count('open_session') > audit_before
            if ((interrupt or terminate) and b'READY' in output or open_started) and not sent:
                if terminate or during_open: os.kill(child,signal.SIGTERM)
                else: os.write(master,b'\x03')
                sent=True
            ended,status=os.waitpid(child,os.WNOHANG)
            if ended:break
        else:
            os.killpg(child,signal.SIGKILL);os.waitpid(child,0)
            raise AssertionError('login helper did not exit: '+repr(output))
    finally:os.close(master)
    return os.waitstatus_to_exitcode(status),output.decode(errors='replace')

code,text=run('id -u; id -ru; printf "USER=%s HOME=%s INJECT=%s\\n" "$USER" "$HOME" "$PYTHONPATH"; exit 23')
assert code==23,(code,text)
assert text.count(str(uid))==2,(code,text)
assert 'USER=fixture HOME=/home/fixture INJECT=' in text,text
assert Path('/tmp/pam-audit').read_text()=='open_session:fixture\nclose_session:fixture\n'
code,text=run('printf READY; exec sleep 30',interrupt=True)
assert code==130,(code,text)
assert Path('/tmp/pam-audit').read_text().count('close_session:fixture')==2
for _ in range(20):
    code,text=run('printf READY; exec sleep 30',terminate=True)
    assert code==143,(code,text)
assert Path('/tmp/pam-audit').read_text().count('close_session:fixture')==22
Path('/etc/pam.d/illogical').write_text(policy.replace('account required pam_permit.so','account required pam_deny.so'))
code,text=run('echo UNAUTHORIZED_COMMAND_EXECUTED')
assert code!=0 and 'UNAUTHORIZED_COMMAND_EXECUTED' not in text,(code,text)
assert Path('/tmp/pam-audit').read_text().count('open_session:fixture')==22
# Match NixOS's normal account/auth/session control flow using real pam_unix.
Path('/etc/pam.d/illogical').write_text('auth sufficient pam_unix.so likeauth try_first_pass\nauth required pam_deny.so\naccount required pam_unix.so\nsession required pam_unix.so\nsession required pam_loginuid.so\nsession required pam_exec.so /usr/local/bin/pam-audit\n')
code,text=run('printf "LOGINUID="; cat /proc/self/loginuid')
assert code==0 and 'LOGINUID='+str(uid) in text,(code,text)
assert Path('/tmp/pam-audit').read_text().count('close_session:fixture')==23
Path('/tmp/illogical-limits').write_text('fixture soft nofile 128\n')
with Path('/etc/pam.d/illogical').open('a') as policy_file:
    policy_file.write('session required pam_limits.so conf=/tmp/illogical-limits\n')
code,text=run('printf "NOFILE="; ulimit -n')
assert code==0 and 'NOFILE=128' in text,(code,text)
code,text=run('echo UNAUTHORIZED_COMMAND_EXECUTED',terminal_owner=0)
assert code!=0 and 'UNAUTHORIZED_COMMAND_EXECUTED' not in text,(code,text)
# Hold PAM open deterministically while delivering a signal to the helper.
Path('/usr/local/bin/pam-audit').write_text('#!/bin/sh\nprintf "%s:%s\\n" "$PAM_TYPE" "$PAM_USER" >> /tmp/pam-audit\nif [ "$PAM_TYPE" = open_session ]; then sleep 0.1; fi\n')
code,text=run('exec sleep 30',during_open=True)
assert code==143,(code,text)
assert Path('/tmp/pam-audit').read_text().count('close_session:fixture')==25
code,text=run("exec python3 -c 'import os; assert os.getpid() == os.getpgrp() == os.tcgetpgrp(0)'")
assert code==0,(code,text)
print(json.dumps({'same_uid_shell':True,'environment_sanitized':True,'pam_open_close':True,'ctrl_c_cleanup':True,'direct_termination_cleanup_20_runs':True,'pam_account_denial':True,'unix_account_loginuid':True,'pam_user_resource_limit':True,'foreign_terminal_rejected':True,'signal_during_pam_open_cleanup':True,'foreground_process_group':True,'fixture_uid':uid}))
