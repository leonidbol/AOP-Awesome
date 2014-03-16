package coolplugin;

import java.util.HashSet;
import java.util.Set;
import java.util.Iterator;

import org.aspectj.weaver.ResolvedMember;
import org.aspectj.weaver.ResolvedType;
import org.aspectj.weaver.Member;
import org.aspectj.weaver.UnresolvedType;
import org.aspectj.apache.bcel.classfile.annotation.*;
import org.aspectj.weaver.bcel.*;
//import org.aspectj.apache.bcel.generic.*;
import org.aspectj.weaver.AnnotationAJ;
import org.aspectj.apache.bcel.generic.Type;


public class Utils {

	public final static UnresolvedType COOL_ASPECT_ANNOTATION = UnresolvedType
	.forName("cool.runtime.COOLAspect");

public final static UnresolvedType COOL_ConditionField_ANNOTATION = UnresolvedType
	.forName("cool.runtime.COOLConditionField");

public final static UnresolvedType COOL_CoordinatorField_ANNOTATION = UnresolvedType
	.forName("cool.runtime.COOLCoordinatorField");

public final static UnresolvedType COOL_Lock_ANNOTATION = UnresolvedType
	.forName("cool.runtime.COOLLock");

public final static UnresolvedType COOL_Unlock_ANNOTATION = UnresolvedType
	.forName("cool.runtime.COOLUnlock");

public final static UnresolvedType COOL_OnEntry_ANNOTATION = UnresolvedType
	.forName("cool.runtime.COOLOnEntry");

public final static UnresolvedType COOL_OnExit_ANNOTATION = UnresolvedType
	.forName("cool.runtime.COOLOnExit");

public final static UnresolvedType COOL_Requires_ANNOTATION = UnresolvedType
	.forName("cool.runtime.COOLRequires");

public final static UnresolvedType COOL_ExternalRef_ANNOTATION = UnresolvedType
	.forName("cool.runtime.COOLExternalRef");

public final static UnresolvedType[] COOL_Method_Annotations = new UnresolvedType[] {
	COOL_Lock_ANNOTATION, COOL_Unlock_ANNOTATION,
	COOL_OnEntry_ANNOTATION, COOL_OnExit_ANNOTATION,
	COOL_Requires_ANNOTATION, COOL_ExternalRef_ANNOTATION };
	
	public static String genUniqueMethodName(ResolvedType tgtClass, String candidateName) {
		Set<String> names = new HashSet<String>();
		addAllMethodNames(tgtClass, names);
		return getUniqueName(names, candidateName);
	}
	
	public static String genUniqueFieldName(ResolvedType tgtClass, String candidateName) {
		Set<String> names = new HashSet<String>();
		addAllFieldNames(tgtClass, names);
		return getUniqueName(names, candidateName);
	}
	
	private static void addAllFieldNames(ResolvedType tgtClass, Set<String> names) {
		//BcelObjectType clazz = tgtClass.getBcelObjectType();
		ResolvedType superClass = tgtClass.getSuperclass();
		if (superClass!=null)
			addAllFieldNames(superClass, names);
		ResolvedMember[] fields = tgtClass.getDeclaredFields();
		for (ResolvedMember field:fields)
			names.add(field.getName());
	}	

	private static void addAllMethodNames(ResolvedType tgtClass, Set<String> names) {
		//BcelObjectType clazz = tgtClass.getBcelObjectType();
		ResolvedType superClass = tgtClass.getSuperclass();
		if (superClass!=null)
			addAllMethodNames(superClass, names);
		ResolvedMember[] methods = tgtClass.getDeclaredMethods();
		for (ResolvedMember method:methods)
			names.add(method.getName());
	}
	
	/** Generates a name that (1) starts from <code>prefix</code>, and
	 * (2) do not appear in <code>names</code>
	 * @param names
	 * @param prefix
	 * @return
	 */
	public static String getUniqueName(Set<String> names, String prefix) {
		if (names==null) 
			return prefix;
		String result = prefix;
		int i=0;
		while(names.contains(result)) {
			result = prefix + "_"+ i;
			i++;
		}
		return result;
	}
	
	/**
	 * Returns a COOL annotation on a method, or null if none is present.
	 * 
	 * @param mg
	 * @return
	 */
	public static AnnotationGen getCOOLAnnotation(LazyMethodGen mg) {
		AnnotationGen result = null;
		if (mg == null)
			return result;
		return getCOOLAnnotation(mg.getMemberView());
	}
	
	public static AnnotationGen getCOOLAnnotation(ResolvedMember method) {
		AnnotationGen result = null;
		if (method == null)
			return result;
		AnnotationAJ[] anns = method.getAnnotations();
		for (AnnotationAJ ann : anns)
			for (UnresolvedType type : COOL_Method_Annotations)
				if (ann.getTypeName().equals(type.getName())) {
					result = ((BcelAnnotation) ann).getBcelAnnotation();
					break;
				}
		return result;
	}

	public static AnnotationGen getCOOLFieldAnnotation(ResolvedMember field) {
		AnnotationGen result = null;
		if (field == null)
			return result;
		AnnotationAJ[] anns = field.getAnnotations();
		for (AnnotationAJ ann : anns)
				if (ann.getTypeName().equals(COOL_ConditionField_ANNOTATION.getName())
						|| ann.getTypeName().equals(COOL_CoordinatorField_ANNOTATION.getName())) 
					result = ((BcelAnnotation) ann).getBcelAnnotation();
		return result;
	}
		
	public static ElementValue getAnnotationElementValue(AnnotationGen annotation,
			String elementName) {
		for (Iterator iterator1 = annotation.getValues().iterator(); iterator1
				.hasNext();) {
			NameValuePair element = (NameValuePair) iterator1
					.next();
			if (elementName.equals(element.getNameString()))
				return (ElementValue) element.getValue();
		}
		return null;
	}
	
	public static UnresolvedType getUnresolvedType(ResolvedType type) {
		//System.out.println("FROM ResolvedType:"+type.getName());
		return UnresolvedType.forName(type.getName());
	}

	public static UnresolvedType getUnresolvedType(LazyClassGen clazz) {
		//System.out.println("FROM LazyClassGen:"+clazz.getClassName());
		return UnresolvedType.forName(clazz.getClassName());
	}
		

	public static UnresolvedType getUnresolvedType(UnwovenClassFile classFile) {
		//System.out.println("FROM UnwovenClassFile:"+classFile.getClassName());
		return UnresolvedType.forName(classFile.getClassName());
	}
	
	public static boolean isSameMethod(LazyMethodGen mg, Member meth) {
		if (!(mg.getName().equals(meth.getName())))
			return false;
		Type[] mgTypes = mg.getArgumentTypes();
		UnresolvedType[] methTypes = meth.getParameterTypes();
		if (mgTypes.length!=methTypes.length) return false;
		for (int i=0;i<mgTypes.length;i++)
			if (!(BcelWorld.fromBcel(mgTypes[i]).equals(methTypes[i])))
				return false;
		return true;
	}

}
