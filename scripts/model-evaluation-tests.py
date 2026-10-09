import importlib.util
from pathlib import Path
import unittest

def load(name):
    spec=importlib.util.spec_from_file_location(name,Path(__file__).with_name(name+'.py'))
    module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module

suite=load('make-model-evaluation')
scorer=load('score-model-evaluation')

class EvaluationTests(unittest.TestCase):
    def test_suite(self):
        cases=suite.make_cases()
        self.assertEqual(len(cases),50)
        self.assertEqual(len({case['id'] for case in cases}),50)
        self.assertEqual({c:sum(x['category']==c for x in cases) for c in ['coding','tasks','knowledge','research']},
                         {'coding':15,'tasks':15,'knowledge':10,'research':10})
    def test_missing_and_memory_rejection_do_not_pass(self):
        case=suite.make_cases()[0]
        for status in ['missing','blocked_load','interrupted','error','cancelled']:
            self.assertFalse(scorer.score(case,{'status':status})['passed'])
    def test_code_runs_independent_inputs(self):
        case=suite.make_cases()[0]
        good={'status':'completed','answer':'```javascript\nfunction solve(input){ return input.reduce((a,b)=>a+b,0); }\n```'}
        bad={**good,'answer':'```javascript\nfunction solve(input){ return 0; }\n```'}
        self.assertTrue(scorer.score(case,good)['passed'])
        self.assertFalse(scorer.score(case,bad)['passed'])
    def test_runaway_code_is_bounded(self):
        case=suite.make_cases()[0]
        self.assertFalse(scorer.score(case,{'status':'completed','answer':'```javascript\nfunction solve(){while(true){}}\n```'})['passed'])
    def test_actions_check_arguments_and_honesty(self):
        case=next(c for c in suite.make_cases() if c['id']=='tasks-01')
        good={'status':'completed','answer':'Draft ready. Tap Send.',
              'calls':[{'name':'find_contact','arguments':{'name':'Alex'}},
                       {'name':'send_message','arguments':{'body':'I will arrive at 6.'}}]}
        self.assertTrue(scorer.score(case,good)['passed'])
        self.assertFalse(scorer.score(case,{**good,'answer':'I sent the message.'})['passed'])
        self.assertFalse(scorer.score(case,{**good,'calls':good['calls'][:1]})['passed'])
    def test_research_requires_page_read_and_distinguishes_name_collision(self):
        case=next(c for c in suite.make_cases() if c['id']=='research-01')
        good={'status':'completed','answer':'Copper Lantern, 2024.',
              'calls':[{'name':'web_search','arguments':{'query':'Jordan Fixture1 Exampletown1 painting'}},
                       {'name':'read_page','arguments':{'url':'https://fixtures.invalid/profile/1'}}]}
        self.assertTrue(scorer.score(case,good)['passed'])
        self.assertFalse(scorer.score(case,{**good,'answer':'This person is a chef.'})['passed'])
        self.assertFalse(scorer.score(case,{**good,'calls':[{'name':'web_search'}]})['passed'])
    def test_short_fact_matches_words_not_substrings(self):
        case=next(c for c in suite.make_cases() if 'gold' in c['prompt'])
        self.assertFalse(scorer.score(case,{'status':'completed','answer':'Because I cannot tell you.'})['passed'])
        self.assertTrue(scorer.score(case,{'status':'completed','answer':'Au.'})['passed'])

if __name__=='__main__': unittest.main()
