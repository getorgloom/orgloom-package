// Native SOQL importer. Salesforce parses the query and enforces CRUD/FLS/sharing;
// this boundary rejects writes/locking and bounds the canvas result independently.
public with sharing class OrgLoomNativeQuery {
    public class QueryException extends Exception {}
    public static final Integer RECORD_CAP = 500;

    private class CheckedQuery {
        String soql;
        String objectName;
    }

    private static CheckedQuery check(String input) {
        if (String.isBlank(input) || input.length() > 20000)
            throw new QueryException('Enter a SELECT query of no more than 20,000 characters.');
        String q = input.trim(), masked = '', top = '';
        Boolean quoted = false;
        Integer depth = 0;
        for (Integer i = 0; i < q.length(); i++) {
            String ch = q.substring(i, i + 1);
            if (quoted) {
                masked += ' '; top += ' ';
                if (ch == '\\' && i + 1 < q.length()) { i++; masked += ' '; top += ' '; }
                else if (ch == '\'') quoted = false;
                continue;
            }
            if (ch == '\'') { quoted = true; masked += ' '; top += ' '; continue; }
            if (ch == ';' || ch == '/' || (ch == '-' && i + 1 < q.length() && q.substring(i + 1, i + 2) == '-'))
                throw new QueryException('Comments and multiple statements are not supported.');
            masked += ch;
            if (ch == '(') depth++;
            top += depth == 0 && ch != ')' ? ch : ' ';
            if (ch == ')' && --depth < 0) throw new QueryException('Unbalanced query parentheses.');
        }
        if (quoted || depth != 0) throw new QueryException('Unclosed query string or parentheses.');
        if (!Pattern.compile('(?i)^SELECT\\s+').matcher(top).find() ||
            Pattern.compile('(?i)\\b(FOR|ALL\\s+ROWS|WITH|GROUP\\s+BY|HAVING|TYPEOF)\\b').matcher(masked).find())
            throw new QueryException('Use a read-only SELECT without locking, aggregates or access-mode clauses.');
        Matcher fromClause = Pattern.compile('(?i)\\bFROM\\s+([A-Za-z][A-Za-z0-9_]*)\\b').matcher(top);
        if (!fromClause.find()) throw new QueryException('A root Salesforce object is required.');
        CheckedQuery result = new CheckedQuery();
        result.objectName = OrgLoomNativeController.objectInfo(fromClause.group(1)).getName();
        String selections = top.substring(6, fromClause.start());
        if (!Pattern.compile('(?i)(^|,)\\s*Id\\s*(,|$)').matcher(selections).find())
            throw new QueryException('Include Id in the root SELECT and each child SELECT.');
        Matcher limitClause = Pattern.compile('(?i)\\bLIMIT\\s+(\\d+)\\b').matcher(top);
        if (limitClause.find()) {
            Integer requested = Integer.valueOf(limitClause.group(1));
            if (requested > RECORD_CAP) q = q.substring(0, limitClause.start(1)) + (RECORD_CAP + 1) + q.substring(limitClause.end(1));
        } else {
            Matcher offsetClause = Pattern.compile('(?i)\\bOFFSET\\b').matcher(top);
            Integer at = offsetClause.find() ? offsetClause.start() : q.length();
            q = q.substring(0, at) + ' LIMIT ' + (RECORD_CAP + 1) + ' ' + q.substring(at);
        }
        result.soql = q;
        return result;
    }

    private class Collected {
        List<Id> order = new List<Id>();
        Map<String,Set<Id>> byObject = new Map<String,Set<Id>>();
        Set<Id> seen = new Set<Id>();
        Boolean capped = false;
        void add(SObject row) {
            Map<String,Object> values = row.getPopulatedFieldsAsMap();
            Id id = (Id)values.get('Id');
            if (id == null) throw new QueryException('Include Id in every child SELECT.');
            if (!seen.contains(id)) {
                if (order.size() == RECORD_CAP) { capped = true; return; }
                String name = OrgLoomNativeController.objectInfo(row.getSObjectType().getDescribe().getName()).getName();
                if (!byObject.containsKey(name)) byObject.put(name, new Set<Id>());
                if (byObject.size() > 20) throw new QueryException('Import no more than 20 object types per query.');
                byObject.get(name).add(id); seen.add(id); order.add(id);
            }
            for (Object value : values.values()) if (value instanceof List<SObject>)
                for (SObject child : (List<SObject>)value) add(child);
        }
    }

    public static Object run(Map<String,Object> body) {
        OrgLoomNativeAccess.requireCapability('soql-import');
        CheckedQuery query = check((String)body.get('soql'));
        List<SObject> queried = Database.queryWithBinds(query.soql, new Map<String,Object>(), AccessLevel.USER_MODE);
        Collected selected = new Collected();
        for (SObject row : queried) selected.add(row);
        queried.clear();
        Map<Id,SObject> hydrated = new Map<Id,SObject>();
        for (String name : selected.byObject.keySet()) hydrated.putAll(OrgLoomNativeController.read(name, selected.byObject.get(name), false));
        List<Object> records = new List<Object>(), links = new List<Object>();
        Map<Id,Integer> temps = new Map<Id,Integer>();
        for (Id id : selected.order) if (hydrated.containsKey(id)) {
            Integer temp = records.size() + 1; temps.put(id, temp);
            SObject row = hydrated.get(id);
            records.add(new Map<String,Object>{'tempId'=>temp, 'objectName'=>row.getSObjectType().getDescribe().getName(), 'loadedFromId'=>id, 'values'=>row});
        }
        for (Id id : temps.keySet()) {
            SObject row = hydrated.get(id);
            for (Schema.SObjectField token : row.getSObjectType().getDescribe().fields.getMap().values()) {
                Schema.DescribeFieldResult field = token.getDescribe();
                if (field.getType() != Schema.DisplayType.REFERENCE || !OrgLoomNativeController.supported(field)) continue;
                Id target = (Id)row.get(field.getName());
                if (temps.containsKey(target)) links.add(new Map<String,Object>{'fromId'=>temps.get(id), 'toId'=>temps.get(target), 'fieldName'=>field.getName()});
            }
        }
        return new Map<String,Object>{'objectName'=>query.objectName, 'records'=>records, 'associations'=>links,
            'totalSize'=>records.size(), 'returned'=>records.size(), 'cap'=>RECORD_CAP, 'capped'=>selected.capped, 'fullFields'=>true};
    }
}
