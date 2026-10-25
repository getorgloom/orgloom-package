// Read-only check of the authenticated UAT user's actual object directory.
Map<String,Object> reply=(Map<String,Object>)JSON.deserializeUntyped(OrgLoomNativeController.invoke('objects','{}'));
System.assertEquals(200,reply.get('status'));
List<Object> objects=(List<Object>)reply.get('data');
Integer customCount=0;Set<String> examples=new Set<String>();
for(Object raw:objects){Map<String,Object> item=(Map<String,Object>)raw;String name=(String)item.get('name');if(item.get('custom')==true)customCount++;if(new Set<String>{'Lead','Task','User','Product2','Account','Contact','Case','Opportunity'}.contains(name))examples.add(name);System.assert(!name.toLowerCase().contains('orgloomnative'));}
System.debug(LoggingLevel.ERROR,'NATIVE_DISCOVERY '+JSON.serialize(new Map<String,Object>{'count'=>objects.size(),'customCount'=>customCount,'examples'=>examples}));
