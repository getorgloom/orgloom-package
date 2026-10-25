// Native payload encryption uses Apex AES-CBC + encrypt-then-MAC. The hosted
// payload uses a Node crypto implementation; the existing KEK wrapping is reused.
public without sharing class OrgLoomNativeCrypto {
    public class CryptoException extends Exception {}
    // Same full-length comparison used by the existing package KEK service.
    private static Boolean equalMac(Blob a,Blob b) {
        if(a==null||b==null)return false;
        String x=EncodingUtil.convertToHex(a),y=EncodingUtil.convertToHex(b);if(x.length()!=y.length())return false;
        Integer difference=0;for(Integer i=0;i<x.length();i++)difference|=(Integer)x.charAt(i)^(Integer)y.charAt(i);
        return difference==0;
    }
    public static Blob seal(String plaintext,String context) {
        OrgLoomNativeKek.ensureKek();Blob key=Crypto.generateAesKey(256);
        String wrapped=OrgLoomNativeKek.wrapDek(EncodingUtil.base64Encode(key));
        String ciphertext=EncodingUtil.base64Encode(Crypto.encryptWithManagedIV('AES256',key,Blob.valueOf(plaintext)));
        Blob authKey=Crypto.generateMac('HmacSHA256',Blob.valueOf('orgloom-native-payload-auth-v1'),key);
        String mac=EncodingUtil.base64Encode(Crypto.generateMac('HmacSHA256',Blob.valueOf(context+'|'+wrapped+'|'+ciphertext),authKey));
        return Blob.valueOf(JSON.serialize(new Map<String,Object>{'format'=>'orgloom-native-encrypted','version'=>1,'wrappedKey'=>wrapped,'ciphertext'=>ciphertext,'mac'=>mac}));
    }
    public static String open(Blob envelope,String context) {
        Map<String,Object> value=(Map<String,Object>)JSON.deserializeUntyped(envelope.toString());
        if(value.get('format')!='orgloom-native-encrypted'||String.valueOf(value.get('version'))!='1')throw new CryptoException('Unsupported encrypted canvas format.');
        String wrapped=(String)value.get('wrappedKey'),ciphertext=(String)value.get('ciphertext');
        Blob key=EncodingUtil.base64Decode(OrgLoomNativeKek.unwrapDek(wrapped));
        Blob authKey=Crypto.generateMac('HmacSHA256',Blob.valueOf('orgloom-native-payload-auth-v1'),key);
        Blob expected=Crypto.generateMac('HmacSHA256',Blob.valueOf(context+'|'+wrapped+'|'+ciphertext),authKey);
        if(!equalMac(expected,EncodingUtil.base64Decode((String)value.get('mac'))))throw new CryptoException('Canvas integrity verification failed.');
        return Crypto.decryptWithManagedIV('AES256',key,EncodingUtil.base64Decode(ciphertext)).toString();
    }
}
