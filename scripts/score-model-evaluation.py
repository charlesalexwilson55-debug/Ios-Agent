"""Score actual device results. Missing, interrupted and blocked cases never pass."""
import argparse
import collections
import json
import re
import subprocess
from pathlib import Path

def score(case, result):
    if result.get('status') != 'completed':
        return {'passed':False,'reason':result.get('error') or result.get('status','missing')}
    answer = result.get('answer','')
    raw = result.get('rawAnswer',answer)
    expected = case['expected']
    reasons = []
    if not answer.strip(): reasons.append('Empty final answer')
    if re.search(r'</?(?:think|answer|question|tool_call)(?:\s|>|\?)', answer, re.I):
        reasons.append('Protocol tags visible in final answer')
    if expected.get('forbid') and any(word in answer.lower() for word in expected['forbid']):
        reasons.append('Forbidden claim in answer')
    if expected.get('any') and not any(re.search(r'(?<!\w)'+re.escape(word)+r'(?!\w)',answer,re.I) for word in expected['any']):
        reasons.append('Expected answer or clarification missing')
    if any(word not in answer.lower() for word in expected.get('all',[])):
        reasons.append('Required facts missing')
    calls = result.get('calls',[])
    names = [call['name'] for call in calls]
    if any(name in names for name in expected.get('forbiddenTools',[])):
        reasons.append('Acted before resolving ambiguity')
    if expected.get('clarification') and not re.search(r'\b(?:which|who|do you mean|would you)\b',answer,re.I):
        reasons.append('Did not ask the required clarification')
    if any(name not in names for name in expected.get('required',[])):
        reasons.append('Required tool not called')
    if any(name not in case['tools'] for name in names): reasons.append('Invented or unoffered tool')
    for name, arguments in expected.get('arguments',{}).items():
        candidates = [call.get('arguments',{}) for call in calls if call['name'] == name]
        if not any(all(any(term in str(args.get(key,'')).lower() for term in (value if isinstance(value,list) else [value]))
                       for key,value in arguments.items()) for args in candidates):
            reasons.append(f'Incorrect {name} arguments')
    if expected['kind'] == 'javascript':
        blocks = re.findall(r'```(?:javascript|js)\s*\n(.*?)```', answer, re.S | re.I)
        if not blocks:
            reasons.append('Missing fenced JavaScript')
        else:
            try:
                checker = str(Path(__file__).with_name('evaluation-js-check.js').resolve())
                run = subprocess.run(['node', '--permission', '--allow-fs-read='+checker, '--disable-proto=throw', checker],
                                     input=json.dumps({'code':blocks[0],'tests':expected['tests']}),
                                     text=True,encoding='utf-8',capture_output=True,timeout=3)
                checked = json.loads(run.stdout)
                if checked.get('error'): reasons.append('Code execution: '+checked['error'])
                elif checked['outputs'] != [test['output'] for test in expected['tests']]: reasons.append('Code failed independent inputs')
            except (OSError,ValueError,subprocess.TimeoutExpired) as error:
                reasons.append('Code check failed: '+str(error))
    return {'passed':not reasons,'reason':'; '.join(reasons),
            'protocolCleaned':raw != answer}

def report(suite, results):
    index = {(r['model'],r['caseID']):r for r in results}
    rows = []
    for model in suite['models']:
        for case in suite['cases']:
            result = index.get((model,case['id']),{'status':'missing'})
            rows.append(dict(model=model,caseID=case['id'],category=case['category'],
                             status=result.get('status','missing'),**score(case,result)))
    counts = collections.defaultdict(collections.Counter)
    for row in rows:
        counts[row['model']]['passed' if row['passed'] else 'failed'] += 1
        counts[row['model']][row['status']] += 1
    return {'scope':suite.get('scope',''), 'models':dict(counts),'cases':rows}

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('suite',type=Path)
    parser.add_argument('results',type=Path)
    parser.add_argument('--out',type=Path,default=Path('artifacts/evaluation/report.json'))
    args=parser.parse_args()
    results=[json.loads(line) for line in args.results.read_text(encoding='utf-8').splitlines() if line.strip()]
    output=report(json.loads(args.suite.read_text(encoding='utf-8')),results)
    args.out.parent.mkdir(parents=True,exist_ok=True)
    args.out.write_text(json.dumps(output,indent=2),encoding='utf-8')
    for model, counts in output['models'].items(): print(model,dict(counts))
    print('Report:',args.out)

if __name__=='__main__': main()
