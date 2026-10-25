@IsTest private class OrgLoomNativeCryptoTest {
    @IsTest static void roundTripAndTampering() {
        Blob stored=OrgLoomNativeCrypto.seal('{"Name":"Private fixture"}','org:canvas:1');
        System.assertEquals('{"Name":"Private fixture"}',OrgLoomNativeCrypto.open(stored,'org:canvas:1'));
        System.assert(!stored.toString().contains('Private fixture'));
        try{OrgLoomNativeCrypto.open(stored,'org:other:1');System.assert(false);}catch(OrgLoomNativeCrypto.CryptoException e){System.assert(e.getMessage().contains('integrity'));}
        Map<String,Object> envelope=(Map<String,Object>)JSON.deserializeUntyped(stored.toString());envelope.put('mac',EncodingUtil.base64Encode(Crypto.generateAesKey(256)));
        try{OrgLoomNativeCrypto.open(Blob.valueOf(JSON.serialize(envelope)),'org:canvas:1');System.assert(false);}catch(OrgLoomNativeCrypto.CryptoException e){System.assert(e.getMessage().contains('integrity'));}
    }
}
