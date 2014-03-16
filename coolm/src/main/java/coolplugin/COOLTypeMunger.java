package coolplugin;

import org.aspectj.weaver.*;
import org.aspectj.weaver.bcel.*;

import java.util.*;
import java.lang.reflect.Modifier;

import org.aspectj.apache.bcel.generic.InstructionFactory;
import org.aspectj.apache.bcel.generic.InstructionList;
import org.aspectj.apache.bcel.generic.InstructionHandle;
//import org.aspectj.apache.bcel.generic.TargetLostException;
import org.aspectj.apache.bcel.generic.Type;
import org.aspectj.apache.bcel.generic.FieldGen;
import org.aspectj.apache.bcel.generic.InvokeInstruction;
import org.aspectj.apache.bcel.generic.Instruction;
import org.aspectj.apache.bcel.classfile.ConstantPool;
import org.aspectj.apache.bcel.classfile.annotation.*;

public class COOLTypeMunger {

	private final BcelWorld world;

	// maps type of a target class to a field name to a getter member
	// this specifies
	// (1) what methods should be introduced into the target class
	// (2) how to introduce external references into the aspect class
	private final Map<UnresolvedType, Map<String, Member>> getterMethods = new HashMap<UnresolvedType, Map<String, Member>>();

	// maps an aspect type
	// to extRef method name to extRef expression string
	// to be used for extRef munging
	private final Map<UnresolvedType, Map<String, String>> extRefs = new HashMap<UnresolvedType, Map<String, String>>();

	// maps an aspect type
	// to extRef method name to return type of this method (type of expression)
	// to be used for extRef munging
	private final Map<UnresolvedType, Map<String, ResolvedType>> extRefTypes = new HashMap<UnresolvedType, Map<String, ResolvedType>>();

	// maps a target class type
	// to the name of the coordinator field.
	private final Map<UnresolvedType, String> coordFields = new HashMap<UnresolvedType, String>();

	public COOLTypeMunger(BcelWorld world) {
		this.world = world;
	}

	public void clear() {
		this.getterMethods.clear();
		this.extRefs.clear();
		this.extRefTypes.clear();
		this.coordFields.clear();
	}

	public boolean isGetterMethod(UnresolvedType tgtUType, String mname) {
		Map<String, Member> tgtGetters = getterMethods.get(tgtUType);
		if (tgtGetters != null)
			for (Member meth : tgtGetters.values())
				if (meth.getName().equals(mname))
					return true;
		return false;
	}

	public ResolvedMember getExternalField(UnresolvedType tgtUType, String mname) {
		Map<String, Member> tgtGetters = getterMethods.get(tgtUType);
		if (tgtGetters != null)
			for (String fieldName : tgtGetters.keySet()) {
				Member meth = tgtGetters.get(fieldName);
				if (meth.getName().equals(mname))
					try {
						return getField(world.resolve(tgtUType), fieldName);
					} catch (Exception e) {
						return null;
					}
			}
		return null;
	}

	public boolean isSynthetic(LazyMethodGen mg) {
		UnresolvedType clType = Utils.getUnresolvedType(mg.getEnclosingClass());
		Map<String, Member> tgtGetterMethods = getterMethods.get(clType);
		if (tgtGetterMethods != null) {
			for (Member meth : tgtGetterMethods.values())
				if (Utils.isSameMethod(mg, meth))
					return true;
		}
		return false;
	}

	public Member getGetterMethod(UnresolvedType tgtType, String fieldName) {
		Map<String, Member> tgtGetters = getterMethods.get(tgtType);
		if (tgtGetters != null)
			return tgtGetters.get(fieldName);
		else
			return null;
	}

	public String getCoordFieldName(UnresolvedType tgtType) {
		return coordFields.get(tgtType);
	}

	// sets up the mappings that are used at munging stage
	public void prepare(ResolvedType aspectType, ResolvedType tgtType)
			throws Exception {
		// clear();
		// System.out.println("Preparing for weaving aspectTYpe = "
		// +aspectType.getName()+", target type = "+tgtType.getName());
		// external fieldNames (names of the fields in the coordinated class)
		Set<String> extFieldNames = new HashSet<String>();

		// getting the right information from the aspect class
		UnresolvedType aspectUType = Utils.getUnresolvedType(aspectType);
		UnresolvedType tgtUType = Utils.getUnresolvedType(tgtType);

		Map<String, String> aspExtRefs = new HashMap<String, String>();
		extRefs.put(aspectUType, aspExtRefs);
		Map<String, ResolvedType> aspExtRefTypes = new HashMap<String, ResolvedType>();
		extRefTypes.put(aspectUType, aspExtRefTypes);

		for (ResolvedMember method : aspectType.getDeclaredMethods()) {
			AnnotationGen ann = Utils.getCOOLAnnotation(method);
			if (ann == null)
				continue;
			String typeName = ann.getTypeName();
			if (typeName.equals(Utils.COOL_ExternalRef_ANNOTATION.getName())) {
				String exprStr = Utils.getAnnotationElementValue(ann, "expr")
						.stringifyValue();
				//System.out.println("Found extRef method " + method.getName()
				//		+ " that targets field: " + getFieldName(exprStr));
				aspExtRefs.put(method.getName(), exprStr);
				ResolvedType retType = world.resolve(method.getReturnType());
				aspExtRefTypes.put(method.getName(), retType);
				extFieldNames.add(getFieldName(exprStr));
			}
		}

		Map<String, Member> tgtGetterMethods = new HashMap<String, Member>();
		getterMethods.put(tgtUType, tgtGetterMethods);

		// filling up all the getter methods
		for (String fieldName : extFieldNames) {
			Member field = getField(tgtType, fieldName);
			if (field == null)
				throw new Exception(" field " + fieldName + " in class "
						+ tgtType.getName() + " is not found!");
			if (field.isStatic())
				throw new Exception(
						"Field "
								+ field.getName()
								+ " that is accessed in the external reference expression is static. "
								+ "Non-static field is expected. ");

			// field is public, so it's OK
			if ((field.getModifiers() & Modifier.PUBLIC) != 0)
				continue;

			String methName = "_get" + fieldName.substring(0, 1).toUpperCase();
			if (fieldName.length() > 1)
				methName = methName + fieldName.substring(1);

			methName = Utils.genUniqueMethodName(tgtType, methName);

			Member method = MemberImpl.method(tgtUType, Modifier.PUBLIC, field
					.getReturnType(), methName, new UnresolvedType[0]);

			tgtGetterMethods.put(fieldName, method);

		}

		String aspectFieldName = Utils.genUniqueFieldName(tgtType, "_coord");
		coordFields.put(tgtUType, aspectFieldName);
	}

	public void transformAspectClass(LazyClassGen aspectClass,
			UnresolvedType tgtUType) throws Exception {
		InstructionFactory fact = aspectClass.getFactory();
		ConstantPool cpg = aspectClass.getConstantPool();
		UnresolvedType aspectUType = Utils.getUnresolvedType(aspectClass);

		Map<String, String> aspExtRefs = extRefs.get(aspectUType);
		// external reference method to expected external reference type
		Map<String, ResolvedType> aspExtRefTypes = extRefTypes.get(aspectUType);
		// all the manager methods in the aspect class
		Map<String, Member> tgtGetterMethods = getterMethods.get(tgtUType);

		List<LazyMethodGen> methods = aspectClass.getMethodGens();

		// transforming all manager methods by replacing
		// calls to external reference methods with
		// actual external variable reference expressions
		for (LazyMethodGen method : methods) {
			AnnotationGen ann = Utils.getCOOLAnnotation(method);
			if (ann == null)
				continue;
			String typeName = ann.getTypeName();
			if (typeName.equals(Utils.COOL_OnEntry_ANNOTATION.getName())
					|| typeName.equals(Utils.COOL_OnExit_ANNOTATION.getName())) {
				InstructionList body = method.getBody();
				InstructionHandle h = body.getStart();
				while (h != null) {
					InstructionHandle next = h.getNext();
					Instruction i = h.getInstruction();
					if (i != null && (i instanceof InvokeInstruction)) {
						InvokeInstruction inv = (InvokeInstruction) i;
						String tgtMethName = inv.getMethodName(cpg);
						String extRef = aspExtRefs.get(tgtMethName);
						if (extRef != null) {
							InstructionList extRefIL = new InstructionList();
							String fieldName = getFieldName(extRef);
							ResolvedType actualType;
							try {
								actualType = compileExternalRef(extRef, fact,
										world.resolve(tgtUType),
										tgtGetterMethods.get(fieldName),
										extRefIL);
							} catch (Exception e) {
								throw new Exception(
										"Error in the external reference expression "
												+ extRef + ": "
												+ e.getMessage());
							}
							ResolvedType expectedType = aspExtRefTypes
									.get(tgtMethName);
							if (!expectedType.isAssignableFrom(actualType))
								throw new Exception(
										"Type error in the external reference expression "
												+ extRef
												+ ": expected type of the expression ("
												+ expectedType
												+ ") is not "
												+ "assignable from its actual type ("
												+ actualType + ")");
							extRefIL.append(Utility.createConversion(fact,
									BcelWorld.makeBcelType(actualType),
									BcelWorld.makeBcelType(expectedType)));

							InstructionHandle h_load_this = h.getPrev()
									.getPrev();
							InstructionHandle extRefIH = body.append(h,
									extRefIL);
							Utility.deleteInstruction(h, extRefIH, method);
							Utility.deleteInstruction(h_load_this, extRefIH,
									method);
						}
					}
					h = next;
				}
			}

		}
	}

	public FieldGen transformTargetClass(LazyClassGen tgtClass,
			UnresolvedType aspectUType) throws Exception {
		FieldGen coordField = addCoordinatorField(tgtClass, aspectUType);// aspectClass.getType());
		// field name accessed in an external reference to getter method for
		// that field
		UnresolvedType tgtUType = Utils.getUnresolvedType(tgtClass);
		Map<String, Member> tgtGetterMethods = getterMethods.get(tgtUType);
		if (tgtGetterMethods != null)
			// munging in the getter methods
			for (String fieldName : tgtGetterMethods.keySet()) {
				Member field = this.getField(tgtClass.getType(), fieldName);
				Member meth = tgtGetterMethods.get(fieldName);
				addFieldGetterMethod(tgtClass, field, meth);
			}
		return coordField;
	}

	private FieldGen addCoordinatorField(LazyClassGen tgtClass,
			UnresolvedType aspectType) {
		String aspectFieldName = coordFields.get(Utils
				.getUnresolvedType(tgtClass));

		FieldGen field = new FieldGen(Modifier.PRIVATE, BcelWorld
				.makeBcelType(aspectType), aspectFieldName, tgtClass
				.getConstantPool());
		//System.out.println("About to add field " + field.getSignature() + "  "
		//		+ field.getName() + " into class " + tgtClass.getClassName());
		tgtClass.addField(field, null);
		return field;
	}

	private LazyMethodGen addFieldGetterMethod(LazyClassGen tgtClass,
			Member field, Member meth) throws Exception {
		LazyMethodGen method = new LazyMethodGen(Modifier.PUBLIC, BcelWorld
				.makeBcelType(meth.getReturnType()), meth.getName(),
				new Type[0], new String[0], tgtClass);

		// generating the body of the method
		InstructionFactory fact = tgtClass.getFactory();
		method.getBody().append(InstructionFactory.ALOAD_0);

		method.getBody().append(Utility.createGet(fact, field));
		method.getBody().append(
				InstructionFactory.createReturn(BcelWorld.makeBcelType(meth
						.getReturnType())));
		tgtClass.addMethodGen(method);
		return method;
	}

	private ResolvedType compileExternalRef(String extRef,
			InstructionFactory fact, ResolvedType declType, Member getterMeth,
			InstructionList il) throws Exception {
		if (extRef == null || extRef.length() == 0)
			return declType;

		String fieldName = getFieldName(extRef);

		if (getterMeth != null) {

			il.append(Utility.createInvoke(fact, world, getterMeth));
			declType = world.resolve(getterMeth.getReturnType());
		} else if (declType.isArray()) {
			if (fieldName.equals("length")) {
				il.append(InstructionFactory.ARRAYLENGTH);
				declType = world.resolve(ResolvedType.INT);
			} else
				throw new Exception("Unknown array field: " + fieldName);
		} else {
			Member field = getField(declType, fieldName);
			if (field == null)
				throw new Exception("field " + fieldName + " in type "
						+ declType.getName() + " is not found!");
			il.append(Utility.createGet(fact, field));
			declType = world.resolve(field.getReturnType());
		}
		return compileExternalRef(getNextRef(extRef), fact, declType, null, il);
	}

	private String getFieldName(String extRef) {
		int nextDot = extRef.indexOf(".");
		return (nextDot < 0) ? extRef : extRef.substring(0, nextDot);
	}

	private String getNextRef(String extRef) {
		int nextDot = extRef.indexOf(".");
		return (nextDot < 0) ? extRef = "" : extRef.substring(nextDot + 1);
	}

	/**
	 * <code>
	 public void transformClasses(LazyMethodGen aspectMeth, String extRefExpr,
	 LazyClassGen tgtClass) throws Exception {
	 Type aspectType = BcelWorld.makeBcelType(aspectMeth.getMemberView()
	 .getDeclaringType());
	 LazyMethodGen getterMeth = addMethod(tgtClass, aspectType, extRefExpr);

	 syntheticMethods.add(getterMeth);
	 // TODO: check the return type of the getterMethod
	 // against return type of the aspectMeth
	 // The return type of the aspectMeth should be wider (or equal)
	 // to the getterMethod. Otherwise, report an error.
	 transformAspectMethod(aspectMeth, getterMeth);
	 }

	 private void transformAspectMethod(LazyMethodGen aspectMeth,
	 LazyMethodGen tgtMeth) throws Exception {
	 System.out.println("transforming an external reference method "
	 + aspectMeth.getName() + " to call " + tgtMeth.getName());
	 InstructionFactory fact = aspectMeth.getEnclosingClass().getFactory();
	 InstructionList il = new InstructionList();
	 il.append(InstructionFactory.ALOAD_1);
	 il.append(InstructionFactory.ALOAD_0);
	 il.append(Utility.createInvoke(fact, tgtMeth));
	 // Type tgtMethRetType = tgtMeth.getReturnType();
	 Type aspMethRetType = aspectMeth.getReturnType();
	 // il.append(Utility.createConversion(fact, tgtMethRetType,
	 // aspMethRetType);
	 il.append(InstructionFactory.createReturn(aspMethRetType));

	 InstructionList body = aspectMeth.getBody();
	 InstructionHandle start = body.getStart();
	 InstructionHandle newStart = body.append(il);
	 while (start != newStart) {
	 InstructionHandle next = start.getNext();
	 Utility.deleteInstruction(start, newStart, aspectMeth);
	 start = next;
	 }
	 } 

	 private LazyMethodGen addMethod(LazyClassGen tgtClass, Type aspectType,
	 String fieldRef) throws Exception {
	 InstructionFactory fact = tgtClass.getFactory();
	 InstructionList il = new InstructionList();
	 int nextDot = fieldRef.indexOf(".");
	 String fieldName;
	 if (nextDot < 1) {
	 fieldName = fieldRef;
	 fieldRef = "";
	 } else {
	 fieldName = fieldRef.substring(0, nextDot);
	 fieldRef = fieldRef.substring(nextDot + 1);
	 }
	 // TODO: ensure that new method does not override
	 // existing method in the target class (or any of its subclasses)
	 String methodName = "_" + fieldName;

	 Member field = getField(tgtClass.getType(), fieldName);
	 if (field == null)
	 throw new Exception(" field " + fieldName + " in class "
	 + tgtClass.getType().getName() + " is not found!");

	 if (field.isStatic())
	 throw new Exception(
	 "COOL error: Field "
	 + field.getSignature()
	 + " that is accessed in the external reference expression is static. Must be instance variable. ");
	 il.append(InstructionFactory.ALOAD_0);
	 il.append(Utility.createGet(fact, field));

	 UnresolvedType returnType = field.getType();
	 while (fieldRef.length() > 0) {
	 nextDot = fieldRef.indexOf(".");
	 if (nextDot < 1) {
	 fieldName = fieldRef;
	 fieldRef = "";
	 } else {
	 fieldName = fieldRef.substring(0, nextDot);
	 fieldRef = fieldRef.substring(nextDot + 1);
	 }

	 UnresolvedType declType = field.getType();
	 if (declType.isArray()) {
	 if (fieldName.equals("length")) {
	 il.append(InstructionFactory.ARRAYLENGTH);
	 returnType = ResolvedType.INT;
	 } else
	 throw new Exception("Unknown array field: " + fieldName);
	 } else {
	 field = getField(world.resolve(declType), fieldName);
	 returnType = field.getType();
	 if (field == null)
	 throw new Exception(" field " + fieldName + " in class "
	 + declType.getName() + " is not found!");
	 il.append(Utility.createGet(fact, field));
	 }
	 }
	 il.append(InstructionFactory.createReturn(BcelWorld
	 .makeBcelType(returnType)));
	 // il.append()

	 LazyMethodGen result = new LazyMethodGen(Modifier.PUBLIC, BcelWorld
	 .makeBcelType(returnType), methodName,
	 new Type[] { aspectType }, new String[0], tgtClass);
	 result.getBody().append(il);
	 tgtClass.addMethodGen(result);
	 System.out.println("adding a method " + result.getSignature()
	 + " to target class " + tgtClass.getClassName());
	 return result;
	 }
	 </code>
	 */
	private ResolvedMember getField(ResolvedType tgtClass, String fieldName)
			throws Exception {
		// BcelObjectType clazz = tgtClass.getBcelObjectType();
		ResolvedMember[] fields = tgtClass.getDeclaredFields();
		for (ResolvedMember field : fields)
			if (field.getName().equals(fieldName))
				return field;
		ResolvedType superClass = tgtClass.getSuperclass();
		if (superClass != null)
			return getField(superClass, fieldName);
		else
			return null;
	}

}
