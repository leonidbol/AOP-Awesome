package coolplugin;

import org.aspectj.weaver.Member;
import org.aspectj.weaver.bcel.BcelShadow;
import org.aspectj.weaver.bcel.Range;

public class COOLLockEffect extends COOLCoordEffect {

	public COOLLockEffect(String aspectClassName, String aspectMethodName, Member target, String fieldName) {
		super (aspectClassName, aspectMethodName, target, fieldName);
	}
	
	public void transform(BcelShadow shadow) {
		//System.err.println("Weaving Lock advice!");
		shadow.getRange().insert(
	    		getAdviceInstructions(shadow),
		        Range.InsideBefore);
	}

}
