package coolplugin;

import org.aspectj.weaver.Member;
import org.aspectj.weaver.UnresolvedType;
import org.aspectj.weaver.bcel.BcelShadow;

public class COOLUnlockEffect extends COOLCoordEffect {
	public COOLUnlockEffect(String aspectClassName, String aspectMethodName, Member target, String fieldName) {
		super (aspectClassName, aspectMethodName, target, fieldName);
	}
	
	public void transform(BcelShadow shadow) {
     // System.err.println("Weaving Unlock advice!");
      weaveAfterThrowing(shadow, UnresolvedType.THROWABLE);
      weaveAfterReturning(shadow);
	}
}
