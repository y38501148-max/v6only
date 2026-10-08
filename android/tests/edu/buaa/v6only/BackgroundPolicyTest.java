package edu.buaa.v6only;
public class BackgroundPolicyTest {
 public static void main(String[] args){
  String[][] cases={{"vivo","iqoo","iQOO"},{"vivo","vivo","vivo"},{"Xiaomi","redmi","小米 / Redmi / POCO"},{"poco","poco","小米 / Redmi / POCO"},{"HUAWEI","huawei","华为"},{"HONOR","honor","荣耀"},{"OPPO","oppo","OPPO"},{"OnePlus","oneplus","一加"},{"realme","realme","realme"},{"samsung","samsung","三星"},{"Google","google","Android"}};
  for(String[] c:cases){String b=BackgroundPolicy.brand(c[0],c[1]);if(!b.equals(c[2]))throw new AssertionError(b);if(BackgroundPolicy.guidance(b).isEmpty())throw new AssertionError();if(!b.equals("Android")&&BackgroundPolicy.components(b).length==0)throw new AssertionError(b);}
  System.out.println("Background settings: 11 manufacturer/alias cases passed");
 }
}
