package awesome.platform;

import java.util.*;

import org.aspectj.apache.bcel.classfile.ConstantPool;
import org.aspectj.apache.bcel.generic.*;
import org.aspectj.apache.bcel.Constants;
import org.aspectj.bridge.context.CompilationAndWeavingContext;
import org.aspectj.bridge.context.ContextToken;
import org.aspectj.weaver.NameMangler;
import org.aspectj.weaver.Shadow;
import org.aspectj.weaver.IClassFileProvider;
import org.aspectj.weaver.bcel.BcelShadow;
import org.aspectj.weaver.bcel.BcelWorld;
import org.aspectj.weaver.bcel.ExceptionRange;
import org.aspectj.weaver.bcel.LazyClassGen;
import org.aspectj.weaver.bcel.LazyMethodGen;
import org.aspectj.weaver.Member;
import org.aspectj.weaver.ResolvedMember;
public class MultiMechanism {
	
	private BcelWorld world;
	private List<IMechanism> mechanisms;

	private Map<LazyMethodGen, List<BcelShadow>> methodShadows = new HashMap<LazyMethodGen, List<BcelShadow>>();

	public MultiMechanism(BcelWorld world) {
		System.out.println("MultiMechanism: "+this);
		this.world = world;
		this.mechanisms = new ArrayList<IMechanism>();
	}
	

	public void setInputFiles(IClassFileProvider input) {
		for (IMechanism mech:mechanisms) 
			mech.setInputFiles(input);
	}
	
	public void addMechanism(IMechanism mechanism) {
		mechanisms.add(mechanism);
	}
	
	public List<BcelShadow> reify(LazyClassGen clazz) {
		List<LazyMethodGen> methods = new ArrayList(clazz.getMethodGens());
		List<BcelShadow> result = new ArrayList<BcelShadow>();
		for (LazyMethodGen mg : methods) {
			List<BcelShadow> methShadows = null;
			methShadows = reify(mg);
			if (methShadows != null) {
				methodShadows.put(mg, methShadows);
				result.addAll(methShadows);
			}
		}
		return result;
	}

	public List<BcelShadow> reify(LazyMethodGen mg) {
		if (!mg.hasBody()) return null;
		BcelShadow enclosingShadow;
		if (mg.getName().equals("<init>")) {
			InstructionHandle superOrThisCall = findSuperOrThisCall(mg);
			// we don't walk bodies of things where it's a wrong constructor
			// thingie
			if (superOrThisCall == null) return null;
			enclosingShadow = BcelShadow.makeConstructorExecution(world, mg, superOrThisCall);
			// TODO:I'm not sure what this statement does. Should it be here?
			if (mg.getEffectiveSignature() != null)
				enclosingShadow.setMatchingSignature(mg.getEffectiveSignature()
						.getEffectiveSignature());
		} else if (mg.getName().equals("<clinit>")) {
			enclosingShadow = BcelShadow.makeStaticInitialization(world, mg);
			// System.err.println(enclosingShadow);
		} else {
			enclosingShadow = BcelShadow.makeMethodExecution(world, mg, false);
		}
		List<BcelShadow> result = reify(mg.getBody(), mg, enclosingShadow);
		enclosingShadow.init();
		result.add(enclosingShadow);
		return result;
	}

	public List<BcelShadow> reify(InstructionList il, LazyMethodGen mg, BcelShadow enclosing) {
		List<BcelShadow> result = new ArrayList<BcelShadow>();
		// ===== Special treatment of init methods
		boolean inEnclosing = true;
		InstructionHandle superOrThisCall = null;
		Shadow.Kind encKind = (enclosing!=null) ? enclosing.getKind() : null;
		if (encKind!=null && encKind == Shadow.ConstructorExecution) {
			inEnclosing = false;
			superOrThisCall = findSuperOrThisCall(mg);
			// enclosing.getRange().getStart().getPrev();
		}
		
        InstructionHandle last = il.getEnd();
        if (last!=null) last = last.getNext();
		for (InstructionHandle h = il.getStart(); h != last; h = h.getNext()) {
			List<BcelShadow> instrShadows = null;
			// Only for init methods
			if (!inEnclosing && encKind!=null && encKind == Shadow.ConstructorExecution
					&& h == superOrThisCall) {
				inEnclosing = true;
				continue; // We are skipping the super/this call instruction.
			}
  		   instrShadows = reify(h, mg, inEnclosing ? enclosing : null);
		   if (instrShadows != null) result.addAll(instrShadows);
		}
		return result;
	}

	/**
	 * SK: The method is designed to identify instruction-level shadows, rather
	 * than method-level shadows.
	 * 
	 * According to the type of instruction, this method invokes specialized
	 * match method (e.g., matchInvokeInstruction). The specialized method
	 * constructs a shadow (by invoking a static make method on the BcelShadow
	 * class that corresponds to the instruction's type), and adds the shadow to
	 * the shadowAccumulator list.
	 * 
	 * The original method was using a bunch of canMatch calls, that I replaced
	 * with truth values. Uses assumptions:
	 * assert(mg.getEnclosingClass()==BcelClassWeaver.clazz);
	 * assert(mg.getEnclosingClass().getConstantPoolGen()==BcelClassWeaver.cpg);
	 * 
	 * @param mg
	 * @param ih
	 * @param enclosingShadow
	 * @param shadowAccumulator
	 */
	public List<BcelShadow> reify(InstructionHandle ih, LazyMethodGen mg,
			BcelShadow enclosingShadow) {
		List<BcelShadow> result = new ArrayList<BcelShadow>();
		// assumption:
		LazyClassGen clazz = mg.getEnclosingClass();
		ConstantPool cpg = clazz.getConstantPool();

		Instruction i = ih.getInstruction();
		if ((i instanceof FieldInstruction)) {
			FieldInstruction fi = (FieldInstruction) i;
			
			Member field = BcelWorld.makeFieldJoinPointSignature(clazz, fi);
			ResolvedMember resolvedField = field.resolve(world);
			
			if (resolvedField == null) {
				// we can't find the field, so it's not a join point.
				return null;
			}				
			if (fi.opcode == Constants.PUTFIELD || fi.opcode == Constants.PUTSTATIC) {
				result.add(BcelShadow.makeFieldSet(world, resolvedField, mg, ih,
						enclosingShadow));
			} else {
				BcelShadow bs = BcelShadow.makeFieldGet(world, mg, ih,
						enclosingShadow);
				String cname = fi.getClassName(cpg);
				// TODO: was different. Check if semantics is preserved.
				// !resolvedField.getDeclaringType().getName().equals(cname))
				if (bs.getSignature().getDeclaringType().getName()
						.equals(cname))
					bs.setActualTargetType(cname);
				result.add(bs);
			}
		} else if (i instanceof InvokeInstruction) {
			InvokeInstruction ii = (InvokeInstruction) i;
			if (ii.getMethodName(clazz.getConstantPool()).equals("<init>")) {
				result.add(BcelShadow.makeConstructorCall(world, mg, ih,
						enclosingShadow));
			} else
				result.add(BcelShadow.makeMethodCall(world, mg, ih,
						enclosingShadow));
		} else
		// TODO: I need to make it shared amongst all the mechanisms,
		// BUT I don't know how it will affect the AJC
		// world.isJoinpointArrayConstructionEnabled() &&
		// if ((i instanceof NEWARRAY || i instanceof ANEWARRAY || i instanceof
		// MULTIANEWARRAY)) {
		if (i.opcode == Constants.ANEWARRAY && world.isJoinpointArrayConstructionEnabled()) {
			//System.out.println("CREATING AN ARRAY CONSTRUCTOR CALL!, isJPARRCONSTRENABLED?="+world.isJoinpointArrayConstructionEnabled());
			result.add(BcelShadow.makeArrayConstructorCall(world, mg, ih,
					enclosingShadow));
		} else if (i.opcode == Constants.NEWARRAY && world.isJoinpointArrayConstructionEnabled()) {
			result.add(BcelShadow.makeArrayConstructorCall(world, mg, ih,
					enclosingShadow));
		} else if (i instanceof MULTIANEWARRAY && world.isJoinpointArrayConstructionEnabled()) {
			result.add(BcelShadow.makeArrayConstructorCall(world, mg, ih,
					enclosingShadow));
		}
		// }
		// performance optimization... we only actually care about ASTORE
		// instructions,
		// since that's what every javac type thing ever uses to start a
		// handler, but for
		// now we'll do this for everybody.
		// TODO: This piece is still AJ-contaminated.
		// Clean it later.
		InstructionTargeter[] targeters = ih.getTargeters().toArray(new InstructionTargeter[0]);
		if (targeters != null) {
			for (int j = 0; j < targeters.length; j++) {
				InstructionTargeter t = targeters[j];
				if (t instanceof ExceptionRange) {
					// assert t.getHandler() == ih
					ExceptionRange er = (ExceptionRange) t;
					if (er.getCatchType() == null)
						continue;
					if (isInitFailureHandler(ih, mg))
						return result;
					result.add(BcelShadow.makeExceptionHandler(world, er, mg,
							ih, enclosingShadow));
				}
			}
		}
		return result;
	}
		

	public boolean transform(LazyClassGen clazz) {
		boolean isChanged = false;
        List<BcelShadow> shadows = reify(clazz);
        for (BcelShadow shadow:shadows)
        	if (transform(shadow)) isChanged=true;
		return isChanged;
	}

	public boolean transform(BcelShadow shadow) {
		//System.out.println("Transforming a shadow:"+shadow+", "+shadow.getSourceLocation());
		
		boolean isChanged = false;
		ContextToken tok = CompilationAndWeavingContext.enteringPhase(
				CompilationAndWeavingContext.IMPLEMENTING_ON_SHADOW, shadow);
		
		List<List<IEffect>> multiEffects = match(shadow);
		List<IEffect> effects = multiOrder(multiEffects, shadow);
		

		//if (effects!=null)
		 // System.out.println("Number of effects:"+effects.size());

		if (effects != null && effects.size() > 0) {
			isChanged = true;
			mix(effects, shadow);
		}
		CompilationAndWeavingContext.leavingPhase(tok);
		return isChanged;
	}

	public List<List<IEffect>> match(BcelShadow shadow) {
		List<List<IEffect>> result = new ArrayList<List<IEffect>>(mechanisms.size());
		for (IMechanism mechanism : mechanisms) {
			List<IEffect> effects = 
				mechanism.order(shadow, mechanism.match(shadow));
			result.add(effects);
		}
		return result;
	}
	
    public List<IEffect> multiOrder(List<List<IEffect>> effects, BcelShadow shadow) {
		List<IEffect> result = new ArrayList<IEffect>();
		for (List<IEffect> eff : effects) 
		  if (eff!=null) result.addAll(eff);
		return result;
    }


	public void mix(List<IEffect> effects, BcelShadow shadow) {
		shadow.prepareForMungers(effects);
		for (IEffect effect : effects)
			effect.transform(shadow);		
	}
	
	public List<BcelShadow> getMethodShadows(LazyMethodGen mg) {
		return methodShadows.get(mg);
	}
	
	/** Mechanisms might use it to add their own associations */
	public void addMethodShadow(LazyMethodGen mg, BcelShadow shadow) {
		List<BcelShadow> shadows = methodShadows.get(mg);
		if (shadows ==null) {
			shadows = new ArrayList<BcelShadow>();
			methodShadows.put(mg, shadows);
		}
		if (!shadows.contains(shadow)) shadows.add(shadow);
	}
	
	/** Mechanisms might use it to remove associations */
	public void removeMethodShadow(LazyMethodGen mg, BcelShadow shadow) {
		List<BcelShadow> shadows = methodShadows.get(mg);
		if (shadows ==null) {
			shadows = new ArrayList<BcelShadow>();
			methodShadows.put(mg, shadows);
		}
		shadows.remove(shadow);
	}
	

	public BcelWorld getWorld() {
		return world;
	}
	
	
	public int getMechanismPos(Class clazz) {
		for (int i=0;i<mechanisms.size();i++)
			if(mechanisms.get(i).getClass()==clazz)
				return i;
		return -1;
	}

	public IMechanism getMechanism(Class clazz) {
		for(IMechanism mech:mechanisms)
			if (mech.getClass()==clazz)
				return mech;
		return null;
	}
	
	
	/**
	 * SK: this method is a filter of synthetic handlers, generated by the
	 * <code>AspectClinit.generatePostSyntheticCode()</code>
	 * 
	 * @param ih
	 * @return
	 */
	private boolean isInitFailureHandler(InstructionHandle ih, LazyMethodGen mg) {
		ConstantPool cpg = mg.getEnclosingClass().getConstantPool();
		// Skip the astore_0 and aload_0 at the start of the handler and
		// then check if the instruction following these is
		// 'putstatic ajc$initFailureCause'. If it is then we are
		// in the handler we created in AspectClinit.generatePostSyntheticCode()
		InstructionHandle twoInstructionsAway = ih.getNext().getNext();
		if (twoInstructionsAway.getInstruction().opcode == Constants.PUTSTATIC) {
			String name = ((FieldInstruction) twoInstructionsAway.getInstruction())
			.getFieldName(cpg);
			if (name.equals(NameMangler.INITFAILURECAUSE_FIELD_NAME))
				return true;
		}
		return false;
	}
	
	/**
	 * TODO: figure out where it should be.
	 * 
	 * @return <code>null</code> if <code>mg</code> does not represent a
	 *         Java constructor. (and then weaver ignores <code>mg</code>).
	 *         Otherwise returns the first super or this call instruction within
	 *         the constructor. The body of the constructor then starts AFTER
	 *         this instruction. Uses assumption
	 *         mg.getEnclosingClass().getConstantPoolGen() = BcelClassWeaver.cpg
	 */
	public static InstructionHandle findSuperOrThisCall(LazyMethodGen mg) {
		int depth = 1;
		InstructionHandle start = mg.getBody().getStart();
		ConstantPool cpg = mg.getEnclosingClass().getConstantPool();
		while (true) {
			if (start == null)
				return null;
			Instruction inst = start.getInstruction();
			if (inst.opcode == Constants.INVOKESPECIAL 
					&& ((InvokeInstruction) inst).getName(cpg).equals("<init>")) {
				depth--;
				if (depth == 0)
					return start;
			} else if (inst.opcode == Constants.NEW) {
				depth++;
			}
			start = start.getNext();
		}
	}

	
}
