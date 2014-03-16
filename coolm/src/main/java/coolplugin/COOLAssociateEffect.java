
package coolplugin;

import java.lang.reflect.Modifier;
import org.aspectj.weaver.*;
import org.aspectj.weaver.bcel.BcelShadow;
import org.aspectj.weaver.bcel.Utility;
import org.aspectj.apache.bcel.Constants;
import org.aspectj.apache.bcel.generic.*;
/**
 * Associates coordinator and coordinated classes
 * by weaving into the coordinated's class constructor
 * a statement that creates an instance of the coordinator's class,
 * and assigns this instance to the _coord  field of the 
 * coordinated class. 
 * @author Sergei
 *
 */
public class COOLAssociateEffect extends COOLEffect {
	private UnresolvedType aspectType;
	private Member aspectField;
	private UnresolvedType targetType;
	
	public COOLAssociateEffect(String aspectClassName, String targetClassName, String aspectFieldName) {		
		init(aspectClassName, targetClassName, aspectFieldName);
	}

	public COOLAssociateEffect(String aspectClassName, String targetClassName) {
		init(aspectClassName, targetClassName, null);
	}

	public COOLAssociateEffect(String aspectClassName, String targetClassName, Member aspectField) {
		this.targetType = UnresolvedType.forName(targetClassName);
		this.aspectType = UnresolvedType.forName(aspectClassName);
		this.aspectField = aspectField;
	}	
	
	private void init(String aspectClassName, String targetClassName, String aspectFieldName) {
		//System.out.println("ASPECT CLASS NAME = "+aspectClassName+", targetClassName = "+targetClassName);

		if (aspectFieldName==null) aspectFieldName = "_coord";
		this.targetType = UnresolvedType.forName(targetClassName);
		this.aspectType = UnresolvedType.forName(aspectClassName);
		//this.aspectField = MemberImpl.field(targetType, Modifier.PRIVATE, aspectFieldName, aspectType);
		this.aspectField = new MemberImpl(MemberImpl.FIELD, 
				targetType, Modifier.PRIVATE, aspectType, 
					aspectFieldName, UnresolvedType.NONE);
	}
	
	public void specializeOn(Shadow shadow) {}
	
	public void transform(BcelShadow shadow) {
	   this.weaveAfterReturning(shadow);
		//weaveBefore(shadow);
	}
	
		
	protected InstructionList getAdviceInstructions(BcelShadow shadow) {
		//invokeCOOLAdvice(Object coordinated, String aspectClassName, String mName)
		InstructionFactory fact = shadow.getFactory();
		InstructionList il = new InstructionList();
		String aspectClassName = aspectType.getSignature();
		//loading target for field setting...
		il.append(InstructionConstants.ALOAD_0);
		//creating a coordinator's instance 
        il.append(fact.createNew(aspectType.getName()));
        il.append(InstructionConstants.DUP);
        il.append(fact.createInvoke(aspectType.getName(), "<init>", Type.VOID, Type.NO_ARGS, Constants.INVOKESPECIAL));
        //assigning the new coordinator instance to the aspectField of the coordinated class
        il.append(Utility.createSet(fact, aspectField));		
		return il;
	}
	
}
