import test from 'node:test';
import assert from 'node:assert/strict';
import { remapCatalog } from '../lib/remap.mjs';
import { mergeCatalog } from '../lib/catalogs.mjs';

test('remaps legacy six-character ids by unique prefix and drops orphans', () => {
  const english = {
    AbCdEf1234: 'Hello {name}',
    XxYyZz0000: 'Bye',
    QqWwEe1111: 'Third',
  };
  const source = {
    AbCdEf: '你好 {name}',
    XxYyZz: '再见',
    Orphan: '无法对应',
  };
  const result = remapCatalog(source, english);
  assert.deepEqual({ ...result.messages }, { AbCdEf1234: '你好 {name}', XxYyZz0000: '再见' });
  assert.deepEqual(
    { exact: result.exact, prefixed: result.prefixed, orphan: result.orphan, ambiguous: result.ambiguous },
    { exact: 0, prefixed: 2, orphan: 1, ambiguous: 0 });
  assert.equal(mergeCatalog(english, result.messages).coverage, 2 / 3);
});

test('exact ids win and ambiguous prefixes are refused', () => {
  const english = { Aaaaaa1111: 'A', Aaaaaa2222: 'B', Bbbbbb3333: 'C' };
  const exact = remapCatalog({ Aaaaaa1111: '甲' }, english);
  assert.equal(exact.exact, 1);
  assert.deepEqual({ ...exact.messages }, { Aaaaaa1111: '甲' });
  const ambiguous = remapCatalog({ Aaaaaa: '甲' }, english);
  assert.equal(ambiguous.ambiguous, 1);
  assert.deepEqual({ ...ambiguous.messages }, {});
});

test('without a current English catalog the source is preserved unchanged', () => {
  const result = remapCatalog({ AbCdEf: '甲' }, null);
  assert.deepEqual({ ...result.messages }, { AbCdEf: '甲' });
  assert.equal(result.prefixed, 0);
});