#!/usr/bin/env python3
"""Merge only AgentIsland's status hooks; preserve existing editor hooks."""
import argparse, json, os, pathlib, shlex, shutil, tempfile, time
from provider_hook import EVENTS

def install(home, providers, apply=False):
    home=pathlib.Path(home)
    script=pathlib.Path(__file__).resolve().with_name('provider_hook.py')
    locations={'cursor':home/'.cursor/hooks.json','windsurf':home/'.codeium/windsurf/hooks.json'}
    for provider in providers:
        path=locations[provider]
        config=json.loads(path.read_text()) if path.exists() else {}
        hooks=config.setdefault('hooks',{})
        if provider=='cursor': config.setdefault('version',1)
        for event in EVENTS[provider]:
            command='/usr/bin/python3 '+shlex.quote(str(script))+' '+provider+' '+event
            entries=hooks.setdefault(event,[])
            if not any(e.get('command')==command for e in entries): entries.append({'command':command})
        print(str(path))
        if not apply: continue
        path.parent.mkdir(parents=True,exist_ok=True)
        if path.exists(): shutil.copy2(path,str(path)+'.agentisland-backup-'+str(time.time_ns()))
        fd,tmp=tempfile.mkstemp(dir=path.parent)
        with os.fdopen(fd,'w') as out:json.dump(config,out,ensure_ascii=False,indent=2)
        os.replace(tmp,path)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--apply',action='store_true');p.add_argument('--home',default=str(pathlib.Path.home()));p.add_argument('providers',nargs='+',choices=EVENTS);a=p.parse_args();install(a.home,a.providers,a.apply)
