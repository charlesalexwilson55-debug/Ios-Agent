import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    assert archive.testzip() is None
    assert archive.namelist() == ['index.html', 'assets/main.js']
    assert archive.read('index.html').decode() == '<h1>Hello</h1>'
    assert archive.read('assets/main.js').decode() == "console.log('hi')"
print('Independent ZIP reader validated names, CRCs and exact file contents')
