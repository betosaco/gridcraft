#!/usr/bin/env python3
"""Verify a disposable macOS package and native Rust MCP; no financial/private inputs."""
from pathlib import Path
import argparse, hashlib, json, os, plistlib, queue, socket, subprocess, tempfile, threading, time, zipfile

class NativeMCP:
    def __init__(self,cli,port=None):
        self.errors=tempfile.TemporaryFile(mode='w+t')
        self.p=subprocess.Popen([cli,'mcp']+(['--connect',str(port)]if port is not None else []),stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=self.errors,text=True,bufsize=1)
        self.seq=0
        self.doc_target=None
        self.lines=queue.Queue()
        def read_lines():
            try:
                for line in self.p.stdout:self.lines.put(line)
            finally:self.lines.put(None)
        threading.Thread(target=read_lines,daemon=True).start()
        try:self.rpc('initialize',{'protocolVersion':'2025-06-18','capabilities':{},'clientInfo':{'name':'dishub-preview-verification','version':'1'}})
        except Exception:
            self.close();raise
    def rpc(self,method,params):
        self.seq+=1
        self.p.stdin.write(json.dumps({'jsonrpc':'2.0','id':self.seq,'method':method,'params':params})+'\n');self.p.stdin.flush()
        deadline=time.monotonic()+60
        while True:
            remaining=deadline-time.monotonic()
            if remaining<=0:raise RuntimeError('Native MCP request timed out: '+method)
            try:line=self.lines.get(timeout=remaining)
            except queue.Empty:raise RuntimeError('Native MCP request timed out: '+method)
            if line is None:raise RuntimeError('Native MCP closed before response: '+method)
            value=json.loads(line)
            if value.get('id')==self.seq:
                if 'error'in value:raise RuntimeError(json.dumps(value['error']))
                return value['result']
    def call(self,name,arguments=None):
        arguments=dict(arguments or {})
        if self.doc_target is not None and name not in {'list_commands','list_functions','list_windows','new_workbook','open_workbook','screenshot'}:
            arguments['doc']=self.doc_target
        r=self.rpc('tools/call',{'name':name,'arguments':arguments})
        if r.get('isError'):raise RuntimeError(json.dumps({'tool':name,'arguments':arguments,'result':r}))
        texts=[x['text']for x in r.get('content',[])if x.get('type')=='text']
        if len(texts)==1:
            try:return json.loads(texts[0])
            except json.JSONDecodeError:return texts[0]
        return r
    def execute(self,command,params=None):return self.call('execute_command',{'command':command,'params':params or {}})
    def read(self,sheet,range,formulas=False):return self.call('read_range',{'sheet':sheet,'range':range,'formulas':formulas})['values']
    def close(self):
        try:
            if not self.p.stdin.closed:self.p.stdin.close()
        finally:
            try:self.p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.p.terminate()
                try:self.p.wait(timeout=5)
                except subprocess.TimeoutExpired:self.p.kill();self.p.wait(timeout=5)
            finally:self.errors.close()

def scientific_check(cli, port, output):
    c=NativeMCP(cli,port)
    proof={'transport':'native Rust MCP','cli':cli,'cliSha256':hashlib.sha256(Path(cli).read_bytes()).hexdigest(),'port':port}
    created=False
    def create_disposable():
        c.doc_target=None
        prior={w['doc']for w in c.call('list_windows')}
        c.execute('file.new')
        new=[w for w in c.call('list_windows')if w['doc']not in prior]
        assert len(new)==1,new
        c.doc_target=new[0]['doc']
        assert not c.call('inspect_workbook').get('path')
    try:
        create_disposable();created=True
        functions=c.execute('formulas.functions',{'search':'MC.'})
        mc={f['name'] for f in functions if f['name'].startswith('MC.')}
        assert mc=={'MC.ACTIVE','MC.POISSON','MC.BINOMIAL','MC.HYPERGEOMETRIC','MC.AR1.NORMAL','MC.AR1.LOGNORMAL'},mc
        actuarial=c.execute('formulas.functions',{'search':'ACT.'})
        assert len([f for f in actuarial if f['name'].startswith('ACT.')])==95
        assert c.execute('formulas.evaluate',{'formula':'=ACT.ANNUITY(1,0)'})==1
        formulas=[['10','=IF(MC.ACTIVE(),MC.POISSON(A1,"orders"),0)','=IF(MC.ACTIVE(),MC.BINOMIAL(B1,0.3,"qualified"),0)','=IF(MC.ACTIVE(),MC.HYPERGEOMETRIC(MIN(4,C1),C1,B1,"capacity"),0)','=IF(MC.ACTIVE(),MC.AR1.LOGNORMAL("cpl",1,10,0.3,0.6),0)','=IF(AND(B1=INT(B1),C1=INT(C1),D1=INT(D1),D1>=0,D1<=C1,C1<=B1),0,1)'],['','','','','=IF(MC.ACTIVE(),MC.AR1.LOGNORMAL("cpl",2,10,0.3,0.6),0)']]
        for row,values in enumerate(formulas,1):
            for col,value in enumerate(values):
                if value:c.execute('cell.set',{'cell':f'{chr(65+col)}{row}','input':value})
        before=c.read('Sheet1','A1:F2')
        params={'inputs':[{'cell':'Sheet1!A1','distribution':'uniform','min':10,'max':10}],'outputs':['Sheet1!B1','Sheet1!C1','Sheet1!D1','Sheet1!E1','Sheet1!E2','Sheet1!F1'],'iterations':64,'seed':20261029,'maxWork':1000000,'samples':True,'newSheet':'Native_Verification'}
        result=c.execute('data.monteCarlo',params)
        assert result['iterations']==64 and result['stochastic']['countRequests']==192,result
        assert result['stochastic']['ar1GeneratedSteps']==128,result['stochastic']
        assert result['outputs'][-1]['min']==result['outputs'][-1]['max']==0
        assert result['outputs'][3]['min']>0 and result['outputs'][4]['min']>0
        assert c.read('Sheet1','A1:F2')==before
        c.execute('edit.undo')
        c.execute('sheet.activate',{'sheet':0})
        assert len(c.call('inspect_workbook')['sheets'])==1
        assert c.read('Sheet1','A1:F2')==before
        c.execute('cell.set',{'cell':'E2','input':'=IF(MC.ACTIVE(),MC.AR1.LOGNORMAL("cpl",0,10,0.3,0.6),0)'})
        invalid_before=c.read('Sheet1','A1:F2')
        refused=False
        try:c.execute('data.monteCarlo',dict(params,newSheet='Must_Not_Publish'))
        except RuntimeError as error:
            assert 'invalid mc.' in str(error).lower(), str(error)
            refused=True
            proof['invalidStepError']=str(error)
        assert refused
        assert c.read('Sheet1','A1:F2')==invalid_before
        assert len(c.call('inspect_workbook')['sheets'])==1
        c.execute('cell.set',{'cell':'E2','input':'=IF(MC.ACTIVE(),MC.AR1.LOGNORMAL("cpl",2,10,0.3,0.6),0)'})
        repeat=c.execute('data.monteCarlo',dict(params,newSheet='Repeat_Verification'))
        assert repeat['outputs']==result['outputs']
        # An actual scoped name must preserve both resolution and the physical caller's stream.
        c.execute('file.close',{'force':True});created=False
        create_disposable();created=True
        c.execute('cell.set',{'cell':'B1','input':'10'})
        c.execute('formulas.defineName',{'name':'Draw','scope':'Sheet1','refersTo':'=MC.POISSON($B$1,"orders")'})
        c.execute('cell.set',{'cell':'A1','input':'=IF(MC.ACTIVE(),Sheet1!Draw,0)'})
        c.execute('home.insertSheet')
        second=c.call('inspect_workbook')['sheets'][-1]['name']
        c.execute('cell.set',{'cell':'B1','input':'99'})
        c.execute('cell.set',{'cell':'A1','input':'=IF(MC.ACTIVE(),Sheet1!Draw,0)'})
        physical={'inputs':[{'cell':'Sheet1!B1','distribution':'uniform','min':10,'max':10}],'outputs':['Sheet1!A1',f"'{second}'!A1"],'iterations':64,'seed':20261029,'maxWork':1000000,'samples':True,'newSheet':'Named_Site_Proof'}
        named=c.execute('data.monteCarlo',physical)
        for sheet in ['Sheet1',second]:c.execute('cell.set',{'cell':f"'{sheet}'!A1",'input':'=IF(MC.ACTIVE(),MC.POISSON(10,"orders"),0)'})
        direct=c.execute('data.monteCarlo',dict(physical,newSheet='Direct_Site_Proof'))
        assert named['outputs']==direct['outputs']
        proof.update(status='PASS',nativeMCFunctions=sorted(mc),actuarialFunctions=95,iterations=64,stochastic=result['stochastic'],sourcePreserved=True,undoPassed=True,invalidStepRefused=True,noReportOnInvalidStep=True,repeatSeedOutputsIdentical=True,scopedPhysicalSitesMatchDirect=True)
    finally:
        try:
            if created:c.execute('file.close',{'force':True})
        finally:c.close()
    Path(output).write_text(json.dumps(proof,indent=2)+'\n')
    return proof

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--dist',required=True,type=Path)
    parser.add_argument('--output',required=True,type=Path)
    parser.add_argument('--expected-commit',required=True)
    args=parser.parse_args()
    root=Path(__file__).resolve().parents[1]
    source=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
    assert source==args.expected_commit
    assert not subprocess.check_output(['git','status','--porcelain'],cwd=root,text=True).strip()
    assert subprocess.check_output(['uname','-m'],text=True).strip()=='arm64'
    edition=json.loads((root/'distribution/edition.json').read_text())
    version=edition['version']
    args.output.mkdir(parents=True,exist_ok=False)
    manifest=json.loads((args.dist/f'dishub-calculo-{version}-macos-aarch64.manifest.json').read_text())
    assert manifest['sourceCommit']==source and manifest['payloadSignatureStatus']=='ad-hoc'
    for item in manifest['artifacts']:
        path=args.dist/item['filename']
        assert path.parent==args.dist and path.is_file()
        assert path.stat().st_size==item['bytes'] and digest(path)==item['sha256']
    work=Path(tempfile.mkdtemp(prefix='dishub-calculo-install-check-'))
    mount=work/'mounted';mount.mkdir()
    log=args.output/'verification.log'
    proof={'status':'RUNNING','sourceCommit':source,'sourceTree':subprocess.check_output(['git','rev-parse','HEAD^{tree}'],cwd=root,text=True).strip(),'workDirectory':str(work),'commercialSignature':False,'notarized':False,'installationScope':'disposable mounted-DMG copy; no /Applications or user books touched','guiLaunch':'PENDING'}
    mounted=False;proc=None
    def run(command, timeout=120):
        with log.open('ab') as stream:
            subprocess.run(command,check=True,stdout=stream,stderr=subprocess.STDOUT,timeout=timeout)
    try:
        dmg=args.dist/f'dishub-calculo-{version}-macos-aarch64.dmg'
        cli_zip=args.dist/f'dishub-calculo-cli-{version}-macos-aarch64.zip'
        run(['hdiutil','verify',str(dmg)])
        run(['hdiutil','attach',str(dmg),'-nobrowse','-readonly','-mountpoint',str(mount)])
        mounted=True
        mounted_bundle=mount/'DisHub Cálculo.app'
        run(['codesign','--verify','--deep','--strict',str(mounted_bundle)])
        bundle=work/'DisHub Cálculo.app'
        run(['ditto',str(mounted_bundle),str(bundle)])
        info=plistlib.loads((bundle/'Contents/Info.plist').read_bytes())
        assert info['CFBundleIdentifier']=='city.dishub.calculo'
        assert info['DisHubCalculoVersion']==version and info['DisHubCalculoBuildCommit']==source
        assert info['LSMinimumSystemVersion']=='11.0'
        run(['codesign','--verify','--deep','--strict',str(bundle)])
        binary=bundle/'Contents/MacOS/DisHubCalculo'
        assert subprocess.check_output(['lipo','-archs',str(binary)],text=True).strip()=='arm64'
        for name in ['LICENSE-MIT','LICENSE-APACHE','NOTICE','ATTRIBUTION.md']:
            assert (bundle/'Contents/Resources'/name).is_file()
        with zipfile.ZipFile(cli_zip) as archive:
            assert all(not Path(name).is_absolute() and '..' not in Path(name).parts for name in archive.namelist())
        run(['ditto','-x','-k',str(cli_zip),str(work/'cli')])
        clients=list((work/'cli').rglob('dishub-calculo-cli'));assert len(clients)==1
        cli=clients[0]
        run(['codesign','--verify','--strict',str(cli)])
        assert subprocess.check_output(['lipo','-archs',str(cli)],text=True).strip()=='arm64'
        expected=f'dishub-calculo-cli {version} (GridCraft base {edition["upstream"]["version"]})'
        assert subprocess.check_output([str(cli),'--version'],text=True).strip()==expected
        scientific_check(str(cli),None,args.output/'packaged-cli-mcp-proof.json')
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1',0));port=reservation.getsockname()[1]
        env=os.environ.copy();env['GRIDCRAFT_CONTROL_PORT']=str(port);env['GRIDCRAFT_NO_PREFS']='1'
        with (args.output/'app.log').open('wb') as stream:
            proc=subprocess.Popen([str(binary)],env=env,stdout=stream,stderr=subprocess.STDOUT)
        ready=False
        for _ in range(120):
            if proc.poll() is not None:raise RuntimeError('Candidate GUI exited before native control readiness')
            try:
                with socket.create_connection(('127.0.0.1',port),timeout=0.1):ready=True;break
            except OSError:time.sleep(0.25)
        if not ready:raise RuntimeError('Candidate GUI did not start its isolated control port')
        scientific_check(str(cli),port,args.output/'packaged-gui-mcp-proof.json')
        proof.update(status='PASS',dmgVerified=True,bundleMetadataVerified=True,signature='ad-hoc verified; not notarized',bundleGuiLaunched=True,guiLaunch='PASS',freshAuthenticatedGuiMCP='95 ACT + 6 MC / 64 trials PASS',packagedCliMCP='PASS',bundleBinarySha256=digest(binary),cliSha256=digest(cli),guiPid=proc.pid,minimumMacOS=info['LSMinimumSystemVersion'])
    except Exception as error:
        proof.update(status='FAIL',error=str(error));raise
    finally:
        errors=[]
        if proc is not None:
            try:
                proc.terminate()
                try:proc.wait(timeout=10)
                except subprocess.TimeoutExpired:proc.kill();proc.wait(timeout=5)
            except Exception as error:errors.append('ownProcessCleanup: '+str(error))
        if mounted:
            try:run(['hdiutil','detach',str(mount)])
            except Exception as error:errors.append('mountCleanup: '+str(error))
        if errors:proof.update(status='FAIL',cleanupErrors=errors)
        (args.output/'mac-installer-proof.json').write_text(json.dumps(proof,indent=2)+'\n')
    assert proof['status']=='PASS'
    print(json.dumps(proof))

if __name__=='__main__':
    main()
