//this is a test comment
package ajplugin;

import java.lang.reflect.Modifier;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.Iterator;
import java.util.List;
import java.util.Map;
import java.util.HashMap;
import java.util.Set;

import org.aspectj.apache.bcel.Constants;
import org.aspectj.apache.bcel.classfile.ConstantPool;
import org.aspectj.apache.bcel.classfile.Field;
import org.aspectj.apache.bcel.generic.Instruction;
import org.aspectj.apache.bcel.generic.FieldInstruction;

import org.aspectj.apache.bcel.generic.FieldGen;
import org.aspectj.apache.bcel.generic.InstructionBranch;
import org.aspectj.apache.bcel.generic.InstructionCP;
import org.aspectj.apache.bcel.generic.InstructionConstants;
import org.aspectj.apache.bcel.generic.InstructionFactory;
import org.aspectj.apache.bcel.generic.InstructionHandle;
import org.aspectj.apache.bcel.generic.InstructionList;
import org.aspectj.apache.bcel.generic.InstructionSelect;
import org.aspectj.apache.bcel.generic.InstructionTargeter;
import org.aspectj.apache.bcel.generic.InvokeInstruction;
import org.aspectj.apache.bcel.generic.LineNumberTag;
import org.aspectj.apache.bcel.generic.LocalVariableTag;
import org.aspectj.apache.bcel.generic.ObjectType;
import org.aspectj.apache.bcel.generic.RET;
import org.aspectj.apache.bcel.generic.Tag;
import org.aspectj.apache.bcel.generic.Type;
import org.aspectj.bridge.MessageUtil;
import org.aspectj.bridge.context.CompilationAndWeavingContext;
import org.aspectj.bridge.context.ContextToken;
import org.aspectj.util.PartialOrder;
import org.aspectj.weaver.AdviceKind;
import org.aspectj.weaver.AjAttribute;
import org.aspectj.weaver.AjcMemberMaker;
import org.aspectj.weaver.BCException;
import org.aspectj.weaver.ConcreteTypeMunger;
import org.aspectj.weaver.IntMap;
import org.aspectj.weaver.Member;
import org.aspectj.weaver.NameMangler;
import org.aspectj.weaver.NewFieldTypeMunger;
import org.aspectj.weaver.ResolvedMember;
import org.aspectj.weaver.ResolvedType;
import org.aspectj.weaver.Shadow;
import org.aspectj.weaver.ShadowMunger;
import org.aspectj.weaver.UnresolvedType;
import org.aspectj.weaver.WeaverMessages;
import org.aspectj.weaver.bcel.BcelClassWeaver.IfaceInitList;
import org.aspectj.weaver.bcel.*;

import awesome.platform.*;

import com.sun.org.apache.bcel.internal.generic.IndexedInstruction;


public aspect AJWeaver extends AbstractWeaver {

	private Map<BcelShadow, List<ShadowMunger>> shadowMungers = new HashMap<BcelShadow, List<ShadowMunger>>();

	private List<BcelShadow> initializationShadows = new ArrayList<BcelShadow>();

	private List<ShadowMunger> mungers = new ArrayList<ShadowMunger>();

	BcelClassWeaver itdWeaver;

	boolean around(MultiMechanism mm, LazyClassGen clazz):
		transformClass(mm, clazz) {
		itdWeaver = new BcelClassWeaver(world, clazz);
		boolean result = itdWeaver.weaveNormalITDs();
		mungers = world.getCrosscuttingMembersSet().getShadowMungers();
		initializationShadows = new ArrayList<BcelShadow>();
		//other guys are accessed directly from itdWeaver
		boolean tmp = proceed(mm, clazz);
		result = tmp || result;
		// if we matched any initialization shadows, we inline and weave
		if (!initializationShadows.isEmpty()) {
			result = true;
			// Repeat next step until nothing left to inline...cant go on 
			// infinetly as compiler will have detected and reported 
			// "Recursive constructor invocation"
			while (inlineSelfConstructors(clazz))
				;
			positionAndImplement(mm, initializationShadows);
		}
		addAspectsAffectingType(mm, clazz);
		return itdWeaver.weaveLateITDs(result);
	}

	/*
	 public void init(List addedSuperInitializersAsList,
	 List addedThisInitializers, Set aspectsAffectingType) {
	 setAddedSuperInitializersAsList(addedSuperInitializersAsList);
	 setAddedThisInitializers(addedThisInitializers);
	 this.aspectsAffectingType = aspectsAffectingType;
	 resetInitializationShadows();
	 resetShadowMungers();
	 } */

	List<BcelShadow> around(MultiMechanism mm, LazyMethodGen mg) :
		reifyMethod(mm, mg) {
		//Transforming synchronized methods 
		if (mg.hasBody() && world.isJoinpointSynchronizationEnabled()
				&& world.areSynchronizationPointcutsInUse()
				&& mg.getMethod().isSynchronized()) {
			transformSynchronizedMethod(mg);
		}
		//If it is not special for AspectJ -> proceed 
		if (!isSpecial(mg))
			return proceed(mm, mg);

		BcelShadow enclosing = null;
		if (mg.isAdviceMethod()) {
			enclosing = BcelShadow.makeAdviceExecution(world, mg);
		} else {
			AjAttribute.EffectiveSignatureAttribute effective = mg
					.getEffectiveSignature();
			if (effective != null && effective.isWeaveBody()) {
				ResolvedMember rm = effective.getEffectiveSignature();
				// Annotations for things with effective signatures are
				// never stored in the effective
				// signature itself - we have to hunt for them. Storing them
				// in the effective signature
				// would mean keeping two sets up to date (no way!!)
				fixAnnotationsForResolvedMember(rm, mg.getMemberView());
				enclosing = BcelShadow.makeShadowForMethod(world, mg, effective
						.getShadowKind(), rm);
			}
		}
		if (enclosing == null)
			return null;

		List<BcelShadow> result = mm.reify(mg.getBody(), mg, enclosing);
		if (result == null)
			result = new ArrayList<BcelShadow>();
		enclosing.init();
		result.add(enclosing);
		return result;
	}

	List<BcelShadow> around(MultiMechanism mm, InstructionHandle ih,
			LazyMethodGen mg, BcelShadow encl) : 
		reifyInstr(mm, ih, mg, encl) {
		if (!isSpecial(ih, mg, encl))
			return proceed(mm, ih, mg, encl);
		return reifySpecial(ih, mg, encl);
	}

	List<BcelShadow> around(MultiMechanism mm, InstructionList il,
			LazyMethodGen mg, BcelShadow encl) : reifyIL(mm, il, mg, encl) {
		List<BcelShadow> result = proceed(mm, il, mg, encl);
		List<BcelShadow> afterShadows = this.getShadowsAfter(mg, encl);
		if (afterShadows != null)
			if (result == null)
				return afterShadows;
			else
				result.addAll(afterShadows);
		return result;
	}

	public List<IEffect> match(BcelShadow shadow) {
		match(shadow, mungers);
		List<IEffect> result = new ArrayList<IEffect>();
		List<ShadowMunger> matching = shadowMungers.get(shadow);
		if (matching != null) {
			for (ShadowMunger munger : matching)
				if (munger instanceof BcelAdvice)
					result.add((BcelAdvice) munger);
		}
		return result;
	}

	/**
	 * Taken from the shadow method. SK: this method sorts advice pieces to be
	 * applied to a join point. The advice pieces are sorted by the
	 * PartialOrder.sort(mungers) method. In case of success (i.e., no circular
	 * dependencies), the mungers field is reset with the ordered set. very
	 * simple.
	 * 
	 */
	public List<IEffect> order(BcelShadow shadow, List<IEffect> effects) {

		List<IEffect> sorted = PartialOrder.sort(effects);

		// Bunch of code to work out whether to report xlints for advice that
		// isn't ordered at this Joinpoint
		possiblyReportUnorderedAdvice(shadow, effects, sorted);

		if (sorted == null) {
			// this means that we have circular dependencies
			for (IEffect eff : effects) {
				if (eff instanceof ShadowMunger)
					world.getMessageHandler().handleMessage(
							MessageUtil.error(WeaverMessages.format(
									WeaverMessages.CIRCULAR_DEPENDENCY, this),
									((ShadowMunger) eff).getSourceLocation()));
			}
		}
		return sorted;
	}

	public List<BcelShadow> getInitializationShadows() {
		return initializationShadows;
	}

	public List<ShadowMunger> getShadowMungers(BcelShadow shadow) {
		return shadowMungers.get(shadow);
	}

	/**
	 * Whether this instruction should be processed by the mechanism, rather
	 * than by the base mechanism.
	 * 
	 * @param ih
	 * @return
	 */
	private boolean isSpecial(InstructionHandle ih, LazyMethodGen mg,
			BcelShadow enclosing) {
		LazyClassGen clazz = mg.getEnclosingClass();
		ConstantPool cpg = clazz.getConstantPool();

		Instruction i = ih.getInstruction();
		if (i instanceof FieldInstruction) {
			FieldInstruction fi = (FieldInstruction) i;
			Member field = BcelWorld.makeFieldJoinPointSignature(clazz, fi);
			// TODO: Should be moved from BM to the MM level!!!
			// synthetic fields are never join points:
			if (field.getName().startsWith(NameMangler.PREFIX))
				return true;
			ResolvedMember resolvedField = field.resolve(world);
			if (resolvedField == null) {
				return true;
			} else if (resolvedField.isSynthetic()) {
				// sets of synthetics aren't join points in 1.1
				return true;
			} else if ((fi.getOpcode() == Constants.PUTFIELD || fi.getOpcode() == Constants.PUTSTATIC)
					&& Modifier.isFinal(resolvedField.getModifiers())
					&& Utility.isConstantPushInstruction(ih.getPrev()
							.getInstruction())) {
				return true;
			}
		} else if (i instanceof InvokeInstruction) {
			InvokeInstruction ii = (InvokeInstruction) i;
			//TODO:figure out if it really what it is supposed to be
			if (ii.getMethodName(clazz.getConstantPool()).equals("<init>")) {
				return false;
			} else if (ii.opcode == Constants.INVOKESPECIAL) {
				String onTypeName = ii.getClassName(cpg);
				// we are a super call, and this is not a join point in
				// AspectJ-1.{0,1}
				if (!onTypeName.equals(clazz.getName())) {
					return true;
				}
			}
			String methodName = ii.getName(cpg);
			if (methodName.startsWith(NameMangler.PREFIX)) {
				return true;
			}
		} else if ((i.getOpcode() == Constants.MONITORENTER) || (i.getOpcode() == Constants.MONITOREXIT)) {
			return true;
		} else if (Range.isRangeHandle(ih))
			return true;
		return false;
	}

	private List<BcelShadow> reifySpecial(InstructionHandle ih,
			LazyMethodGen mg, BcelShadow enclosing) {
		LazyClassGen clazz = mg.getEnclosingClass();
		ConstantPool cpg = clazz.getConstantPool();
		List<BcelShadow> result = new ArrayList<BcelShadow>();
		Instruction i = ih.getInstruction();
		if (i instanceof InvokeInstruction) {
			InvokeInstruction ii = (InvokeInstruction) i;
			if (ii.opcode == Constants.INVOKESPECIAL) {
				String onTypeName = ii.getClassName(cpg);
				// we are a super call, and this is not a join point in
				// AspectJ-1.{0,1}
				if (!onTypeName.equals(mg.getEnclosingClass().getName())) {
					return null;
				}
			}
			Member jpSig = world.makeJoinPointSignatureForMethodInvocation(
					clazz, ii);
			ResolvedMember declaredSig = jpSig.resolve(world);
			// System.err.println(method + ", declaredSig: " +declaredSig);
			if (declaredSig == null)
				return null;
			if (declaredSig.getKind() == Member.FIELD) {
				Shadow.Kind kind;
				if (jpSig.getReturnType().equals(ResolvedType.VOID)) {
					kind = Shadow.FieldSet;
				} else {
					kind = Shadow.FieldGet;
				}
				result.add(BcelShadow.makeShadowForMethodCall(world, mg, ih,
						enclosing, kind, declaredSig));
			} else {
				AjAttribute.EffectiveSignatureAttribute effectiveSig = declaredSig
						.getEffectiveSignature();
				if (effectiveSig == null)
					return null;
				if (effectiveSig.isWeaveBody())
					return null;
				ResolvedMember rm = effectiveSig.getEffectiveSignature();
				fixAnnotationsForResolvedMember(rm, declaredSig); // abracadabra

				result.add(BcelShadow.makeShadowForMethodCall(world, mg, ih,
						enclosing, effectiveSig.getShadowKind(), rm));
			}
		} else if (world.isJoinpointSynchronizationEnabled()
				&& ((i.getOpcode() == Constants.MONITORENTER) || (i.getOpcode() == Constants.MONITOREXIT))) {
			if (i.getOpcode() == Constants.MONITORENTER) {
				BcelShadow monitorEntryShadow = BcelShadow.makeMonitorEnter(
						world, mg, ih, enclosing);
				result.add(monitorEntryShadow);
				// match(monitorEntryShadow,shadowAccumulator);
			} else {
				BcelShadow monitorExitShadow = BcelShadow.makeMonitorExit(
						world, mg, ih, enclosing);
				result.add(monitorExitShadow);
				// match(monitorExitShadow,shadowAccumulator);
			}
		}
		if (result != null && result.size() == 0)
			return null;
		return result;
	}

	private List<BcelShadow> getShadowsAfter(LazyMethodGen mg,
			BcelShadow enclosingShadow) {
		if (mg.getName().equals("<init>")) {
			//System.out.println("Init shadow:"+enclosingShadow+" on method "+mg);
			//System.out.println("Number of addedSuperInits:"+itdWeaver.getAddedSuperInitializersAsList().size());
			List<BcelShadow> result = new ArrayList<BcelShadow>();

			InstructionFactory fact = mg.getEnclosingClass().getFactory();
			LazyClassGen clazz = mg.getEnclosingClass();
			ConstantPool cpg = clazz.getConstantPool();

			InstructionHandle superOrThisCall = MultiMechanism
					.findSuperOrThisCall(mg);
			// XXX we don't do pre-inits of interfaces

			// now add interface inits
			if (superOrThisCall != null && !isThisCall(clazz, superOrThisCall)) {
				//INVOKESPECIAL inst = (INVOKESPECIAL) superOrThisCall
				//		.getInstruction();
				//
				//				if (!(inst.getClassName(cpg).equals(clazz.getName()))) {
				// SK: if instr is a call to this class's initializer, then
				InstructionHandle curr = enclosingShadow.getRange().getStart();

				// For each interface that the advised class (top-most)
				// implements
				for (Iterator i = itdWeaver.getAddedSuperInitializersAsList()
						.iterator(); i.hasNext();) {
					IfaceInitList l = (IfaceInitList) i.next();
					// The constructor signature for ITD's target type is
					// generated
					// (l.onType might be either the same as the advised
					// class,
					// or interface type)
					// It sounds weird, and that's definetely true, because
					// ifaceInitSig is
					// a PURELY descriptive element. It doesn't really makes
					// its
					// way into the code.
					Member ifaceInitSig = AjcMemberMaker
							.interfaceConstructor(l.onType);

					// creates a shadow associated w/ an interface in the
					// body
					// of a constructor
					// Another descriptive element.
					BcelShadow initShadow = BcelShadow.makeIfaceInitialization(
							world, mg, ifaceInitSig);
					//System.out.println("IFaceInit shadow:"+initShadow);

					// Generating initalization instructions for l.list
					// field
					// ITDs
					// (that are defined on the l.onType)
					// The instructions are basically calls to
					// field-initializaer methods
					// defined in ITDs' declaring aspects.
					// The whole thing then represents an l.onType interface
					// initialization shadow.
					InstructionList inits = genInitInstructions(l.list, fact);
					result.add(initShadow);
					//if (!inits.isEmpty()) {
						// This inserts NOP operation before curr
						// AND binds the shadow to this instruction (thus
						// the
						// new-last NOP instruction
						// is shadow's range start & end.
						initShadow.initIfaceInitializer(curr);
						// This, however, inserts the calls outsideBefore
						// (?)
						// the NOP instruction
						// (the body of the range is updated)
						initShadow.getRange()
								.insert(inits, Range.OutsideBefore);
					//}
					// the process repeats for all superInitalizers. It
					// seems
					// that their shadows
					// are thus nested within each other, so that the first
					// encloses all the rest.
				}

				// Then the same is for field ITD's that target declaring
				// class
				// of the mg method
				// (this class). No shadow is generated for this guys.
				InstructionList inits = genInitInstructions(itdWeaver
						.getAddedThisInitializers(), fact);
				// Finally, the field ITD's initializers are added to the
				// constructor
				enclosingShadow.getRange().insert(inits, Range.OutsideBefore);
				//			}
			}

			initializationShadows.add(BcelShadow.makeUnfinishedInitialization(
					world, mg));
			initializationShadows.add(BcelShadow
					.makeUnfinishedPreinitialization(world, mg));

			return result;
		}
		return null;
	}

	/**
	 * The method matches a shadow against a list of shadow mungers. Matching
	 * mungers are associated with the shadow.
	 * 
	 * @param shadow
	 *            is a join point shadow to be matched
	 * @param shadowMungers
	 *            is a list of advice
	 * @return whether the shadow matches any of advice
	 */
	private boolean match(BcelShadow shadow, List<ShadowMunger> shadowMungers) {
		LazyClassGen clazz = shadow.getEnclosingClass();
		boolean isMatched = false;
		// The captureLowLevelContext seem to mean
		// more wordy debug info.
		if (BcelClassWeaver.captureLowLevelContext) { // duplicate blocks - one with context
			// capture, one without, seems faster
			// than multiple 'ifs()'
			ContextToken shadowMatchToken = CompilationAndWeavingContext
					.enteringPhase(
							CompilationAndWeavingContext.MATCHING_SHADOW,
							shadow);
			for (ShadowMunger munger : shadowMungers) {
				ContextToken mungerMatchToken = CompilationAndWeavingContext
						.enteringPhase(
								CompilationAndWeavingContext.MATCHING_POINTCUT,
								munger.getPointcut());
				// the munger.match(shadow, world) matches the shadow against a
				// munger's pointcut
				if (munger.match(shadow, world)) {
					// SK: whatever it means
					//WeaverMetrics.recordMatchResult(true);// Could pass:
					// munger
					addAssociation(shadow, munger);
					isMatched = true;
					// It is Ok here, because we are in the AJ mechanism.
					if (shadow.getKind() == Shadow.StaticInitialization) {
						clazz.warnOnAddedStaticInitializer(shadow, munger
								.getSourceLocation());
					}
				} else {
					//WeaverMetrics.recordMatchResult(false); // Could pass:
					// munger
				}
				CompilationAndWeavingContext.leavingPhase(mungerMatchToken);
			}
			CompilationAndWeavingContext.leavingPhase(shadowMatchToken);
		} else {
			for (ShadowMunger munger : shadowMungers) {
				if (munger.match(shadow, world)) {
					addAssociation(shadow, munger);
					isMatched = true;
					if (shadow.getKind() == Shadow.StaticInitialization) {
						clazz.warnOnAddedStaticInitializer(shadow, munger
								.getSourceLocation());
					}
				}
			}
		}
		return isMatched;
	}

	// ======================= The following is to be moved from BM

	// not quite optimal... but the xlint is ignore by default
	/**
	 * Copied from the Shadow class.
	 *  SK: that's smth not really essential to the advice ordering process. */
	private void possiblyReportUnorderedAdvice(BcelShadow shadow,
			List<IEffect> mungers, List sorted) {
		if (sorted != null
				&& world.getLint().unorderedAdviceAtShadow.isEnabled()
				&& mungers.size() > 1) {

			// Stores a set of strings of the form 'aspect1:aspect2' which
			// indicates there is no
			// precedence specified between the two aspects at this shadow.
			Set clashingAspects = new HashSet();
			int max = mungers.size();

			// Compare every pair of advice mungers
			for (int i = max - 1; i >= 0; i--) {
				for (int j = 0; j < i; j++) {
					IEffect a = mungers.get(i);
					IEffect b = mungers.get(j);
					if ((a instanceof BcelAdvice) && (b instanceof BcelAdvice)) {
						BcelAdvice adviceA = (BcelAdvice) a;
						BcelAdvice adviceB = (BcelAdvice) b;
						if (!adviceA.getConcreteAspect().equals(
								adviceB.getConcreteAspect())) {
							AdviceKind adviceKindA = adviceA.getKind();
							AdviceKind adviceKindB = adviceB.getKind();

							// make sure they are the nice ones (<6) and not any
							// synthetic advice ones we
							// create to support other features of the language.
							if (adviceKindA.getKey() < (byte) 6
									&& adviceKindB.getKey() < (byte) 6
									&& adviceKindA.getPrecedence() == adviceKindB
											.getPrecedence()) {

								// Ask the world if it knows about precedence
								// between these
								Integer order = world.getPrecedenceIfAny(
										adviceA.getConcreteAspect(), adviceB
												.getConcreteAspect());

								if (order != null
										&& order.equals(new Integer(0))) {
									String key = adviceA.getDeclaringAspect()
											+ ":"
											+ adviceB.getDeclaringAspect();
									String possibleExistingKey = adviceB
											.getDeclaringAspect()
											+ ":"
											+ adviceA.getDeclaringAspect();
									if (!clashingAspects
											.contains(possibleExistingKey))
										clashingAspects.add(key);
								}
							}
						}
					}
				}
			}
			for (Iterator iter = clashingAspects.iterator(); iter.hasNext();) {
				String element = (String) iter.next();
				String aspect1 = element.substring(0, element.indexOf(":"));
				String aspect2 = element.substring(element.indexOf(":") + 1);
				world.getLint().unorderedAdviceAtShadow.signal(new String[] {
						this.toString(), aspect1, aspect2 }, shadow
						.getSourceLocation(), null);
			}
		}
	}

	/**
	 * First sorts the mungers, then gens the initializers in the right order
	 * SK: Generates instructions that initialize the ITD fields in
	 * <code>list</code> More specifically, each ITD field is initialized by
	 * calling public static methods defined in the declaring aspect of the
	 * field's ITD. The name of the method is: "ajc$interFieldInit$"+ type of
	 * aspect +"$" + target type of ITD +"$"+ ITD field's name The aspect-based
	 * initializer method contains actual field initialization instructions. The
	 * method returns a list of calls to public static methods, defined in
	 * aspects.
	 * 
	 */
	private InstructionList genInitInstructions(List list,
			InstructionFactory fact) {
		// first, field ITDs are sorted appropriately.
		list = PartialOrder.sort(list);
		if (list == null) {
			throw new BCException("circularity in inter-types");
		}

		InstructionList ret = new InstructionList();

		for (Iterator i = list.iterator(); i.hasNext();) {
			ConcreteTypeMunger cmunger = (ConcreteTypeMunger) i.next();
			NewFieldTypeMunger munger = (NewFieldTypeMunger) cmunger
					.getMunger();
			ResolvedMember initMethod = munger.getInitMethod(cmunger
					.getAspectType());
			// if (!isStatic) ret.append(InstructionConstants.ALOAD_0);
			ret.append(Utility.createInvoke(fact, world, initMethod));
		}
		return ret;
	}

	private Map mapToAnnotations = new HashMap();

	/**
	 * For a given resolvedmember, this will discover the real annotations for
	 * it. <b>Should only be used when the resolvedmember is the contents of an
	 * effective signature attribute, as thats the only time when the
	 * annotations aren't stored directly in the resolvedMember</b>
	 * 
	 * @param rm
	 *            the sig we want it to pretend to be 'int A.m()' or somesuch
	 *            ITD like thing
	 * @param declaredSig
	 *            the real sig 'blah.ajc$xxx'
	 */
	private void fixAnnotationsForResolvedMember(ResolvedMember rm,
			ResolvedMember declaredSig) {
		try {
			UnresolvedType memberHostType = declaredSig.getDeclaringType();
			ResolvedType[] annotations = (ResolvedType[]) mapToAnnotations
					.get(rm);
			String methodName = declaredSig.getName();
			// FIXME asc shouldnt really rely on string names !
			if (annotations == null) {
				if (rm.getKind() == Member.FIELD) {
					if (methodName.startsWith("ajc$inlineAccessField")) {
						ResolvedMember resolvedDooberry = world.resolve(rm);
						annotations = resolvedDooberry.getAnnotationTypes();
					} else {
						ResolvedMember realthing = AjcMemberMaker
								.interFieldInitializer(rm, memberHostType);
						ResolvedMember resolvedDooberry = world
								.resolve(realthing);
						annotations = resolvedDooberry.getAnnotationTypes();
					}
				} else if (rm.getKind() == Member.METHOD && !rm.isAbstract()) {
					if (methodName.startsWith("ajc$inlineAccessMethod")
							|| methodName.startsWith("ajc$superDispatch")) {
						ResolvedMember resolvedDooberry = world
								.resolve(declaredSig);
						annotations = resolvedDooberry.getAnnotationTypes();
					} else {
						ResolvedMember realthing = AjcMemberMaker
								.interMethodDispatcher(rm.resolve(world),
										memberHostType).resolve(world);
						// ResolvedMember resolvedDooberry =
						// world.resolve(realthing);
						ResolvedMember theRealMember = findResolvedMemberNamed(
								memberHostType.resolve(world), realthing
										.getName());
						// AMC temp guard for M4
						if (theRealMember == null) {
							throw new UnsupportedOperationException(
									"Known limitation in M4 - can't find ITD members when type variable is used as an argument and has upper bound specified");
						}
						annotations = theRealMember.getAnnotationTypes();
					}
				} else if (rm.getKind() == Member.CONSTRUCTOR) {
					ResolvedMember realThing = AjcMemberMaker
							.postIntroducedConstructor(memberHostType
									.resolve(world), rm.getDeclaringType(), rm
									.getParameterTypes());
					ResolvedMember resolvedDooberry = world.resolve(realThing);
					// AMC temp guard for M4
					if (resolvedDooberry == null) {
						throw new UnsupportedOperationException(
								"Known limitation in M4 - can't find ITD members when type variable is used as an argument and has upper bound specified");
					}
					annotations = resolvedDooberry.getAnnotationTypes();
				}
				if (annotations == null)
					annotations = new ResolvedType[0];
				mapToAnnotations.put(rm, annotations);
			}
			rm.setAnnotationTypes(annotations);
		} catch (UnsupportedOperationException ex) {
			throw ex;
		} catch (Throwable t) {
			// FIXME asc remove this catch after more testing has confirmed the
			// above stuff is OK
			throw new BCException(
					"Unexpectedly went bang when searching for annotations on "
							+ rm, t);
		}
	}

	/**
	 * For some named resolved type, this method looks for a member with a
	 * particular name - it should only be used when you truly believe there is
	 * only one member with that name in the type as it returns the first one it
	 * finds.
	 */
	private ResolvedMember findResolvedMemberNamed(ResolvedType type,
			String methodName) {
		ResolvedMember[] allMethods = type.getDeclaredMethods();
		for (int i = 0; i < allMethods.length; i++) {
			ResolvedMember member = allMethods[i];
			if (member.getName().equals(methodName))
				return member;
		}
		return null;
	}

	/**
	 * Input method is a synchronized method, we remove the bit flag for
	 * synchronized and then insert a try..finally block
	 * 
	 * Some jumping through firey hoops required - depending on the input code
	 * level (1.5 or not) we may or may not be able to use the LDC instruction
	 * that takes a class literal (doesnt on <1.5).
	 * 
	 * FIXME asc Before promoting -Xjoinpoints:synchronization to be a standard
	 * option, this needs a bunch of tidying up - there is some duplication that
	 * can be removed.
	 */
public static void transformSynchronizedMethod(
			LazyMethodGen synchronizedMethod) {
		// System.err.println("DEBUG: Transforming synchronized method:
		// "+synchronizedMethod.getName());
		final InstructionFactory fact = synchronizedMethod.getEnclosingClass()
				.getFactory();
		InstructionList body = synchronizedMethod.getBody();
		InstructionList prepend = new InstructionList();
		Type enclosingClassType = BcelWorld.makeBcelType(synchronizedMethod
				.getEnclosingClass().getType());
		Type javaLangClassType = Type.getType(Class.class);

		// STATIC METHOD TRANSFORMATION
		if (synchronizedMethod.isStatic()) {

			// What to do here depends on the level of the class file!
			// LDC can handle class literals in Java5 and above *sigh*
			if (synchronizedMethod.getEnclosingClass().isAtLeastJava5()) {
				// MONITORENTER logic:
				// 0: ldc #2; //class C
				// 2: dup
				// 3: astore_0
				// 4: monitorenter
				int slotForLockObject = synchronizedMethod
						.allocateLocal(enclosingClassType);
				prepend.append(fact.createConstant(enclosingClassType));
				prepend.append(InstructionFactory.createDup(1));
				prepend.append(InstructionFactory.createStore(
						enclosingClassType, slotForLockObject));
				prepend.append(InstructionFactory.MONITORENTER);

				// MONITOREXIT logic:

				// We basically need to wrap the code from the method in a
				// finally block that
				// will ensure monitorexit is called. Content on the finally
				// block seems to
				// be always:
				// 
				// E1: ALOAD_1
				// MONITOREXIT
				// ATHROW
				//
				// so lets build that:
				InstructionList finallyBlock = new InstructionList();
				finallyBlock.append(InstructionFactory.createLoad(Type
						.getType(java.lang.Class.class), slotForLockObject));
				finallyBlock.append(InstructionConstants.MONITOREXIT);
				finallyBlock.append(InstructionConstants.ATHROW);

				// finally -> E1
				// | GETSTATIC java.lang.System.out Ljava/io/PrintStream; (line
				// 21)
				// | LDC "hello"
				// | INVOKEVIRTUAL java.io.PrintStream.println
				// (Ljava/lang/String;)V
				// | ALOAD_1 (line 20)
				// | MONITOREXIT
				// finally -> E1
				// GOTO L0
				// finally -> E1
				// | E1: ALOAD_1
				// | MONITOREXIT
				// finally -> E1
				// ATHROW
				// L0: RETURN (line 23)

				// search for 'returns' and make them jump to the
				// aload_<n>,monitorexit
				InstructionHandle walker = body.getStart();
				List rets = new ArrayList();
				while (walker != null) {
					if (walker.getInstruction().isReturnInstruction()) {
						rets.add(walker);
					}
					walker = walker.getNext();
				}
				if (rets.size() > 0) {
					// need to ensure targeters for 'return' now instead target
					// the load instruction
					// (so we never jump over the monitorexit logic)

					for (Iterator iter = rets.iterator(); iter.hasNext();) {
						InstructionHandle element = (InstructionHandle) iter
								.next();
						InstructionList monitorExitBlock = new InstructionList();
						monitorExitBlock.append(InstructionFactory.createLoad(
								enclosingClassType, slotForLockObject));
						monitorExitBlock
								.append(InstructionConstants.MONITOREXIT);
						// monitorExitBlock.append(Utility.copyInstruction(element.getInstruction()));
						// element.setInstruction(InstructionFactory.createLoad(classType,slotForThis));
						InstructionHandle monitorExitBlockStart = body.insert(
								element, monitorExitBlock);

						// now move the targeters from the RET to the start of
						// the monitorexit block
						InstructionTargeter[] targeters = element
								.getTargeters().toArray(new InstructionTargeter[0]);
						if (targeters != null) {
							for (int i = 0; i < targeters.length; i++) {

								InstructionTargeter targeter = targeters[i];
								// what kinds are there?
								if (targeter instanceof LocalVariableTag) {
									// ignore
								} else if (targeter instanceof LineNumberTag) {
									// ignore
								//} else if (targeter instanceof GOTO
								//		|| targeter instanceof GOTO_W) {
									// move it...
								//	targeter.updateTarget(element,
								//			monitorExitBlockStart);
								} else if (targeter instanceof InstructionBranch) {
									// move it
									targeter.updateTarget(element,
											monitorExitBlockStart);
								} else {
									throw new BCException(
											"Unexpected targeter encountered during transform: "
													+ targeter);
								}
							}
						}
					}
				}

				// now the magic, putting the finally block around the code
				InstructionHandle finallyStart = finallyBlock.getStart();

				InstructionHandle tryPosition = body.getStart();
				InstructionHandle catchPosition = body.getEnd();
				body.insert(body.getStart(), prepend); // now we can put the
				// monitorenter stuff on
				synchronizedMethod.getBody().append(finallyBlock);
				synchronizedMethod.addExceptionHandler(tryPosition,
						catchPosition, finallyStart, null/* ==finally */,
						false);
				synchronizedMethod.addExceptionHandler(finallyStart,
						finallyStart.getNext(), finallyStart, null, false);
			} else {

				// TRANSFORMING STATIC METHOD ON PRE JAVA5

				// Hideous nightmare, class literal references prior to Java5

				// YIKES! this is just the code for MONITORENTER !
				// 0: getstatic #59; //Field class$1:Ljava/lang/Class;
				// 3: dup
				// 4: ifnonnull 32
				// 7: pop
				// try
				// 8: ldc #61; //String java.lang.String
				// 10: invokestatic #44; //Method
				// java/lang/Class.forName:(Ljava/lang/String;)Ljava/lang/Class;
				// 13: dup
				// catch
				// 14: putstatic #59; //Field class$1:Ljava/lang/Class;
				// 17: goto 32
				// 20: new #46; //class java/lang/NoClassDefFoundError
				// 23: dup_x1
				// 24: swap
				// 25: invokevirtual #52; //Method
				// java/lang/Throwable.getMessage:()Ljava/lang/String;
				// 28: invokespecial #54; //Method
				// java/lang/NoClassDefFoundError."<init>":(Ljava/lang/String;)V
				// 31: athrow
				// 32: dup <-- partTwo (branch target)
				// 33: astore_0
				// 34: monitorenter
				//			
				// plus exceptiontable entry!
				// 8 13 20 Class java/lang/ClassNotFoundException
				Type classType = BcelWorld.makeBcelType(synchronizedMethod
						.getEnclosingClass().getType());
				Type clazzType = Type.getType(Class.class);

				InstructionList parttwo = new InstructionList();
				parttwo.append(InstructionFactory.createDup(1));
				int slotForThis = synchronizedMethod.allocateLocal(classType);
				parttwo.append(InstructionFactory.createStore(clazzType,
						slotForThis)); // ? should be the real type ? String or
				// something?
				parttwo.append(InstructionFactory.MONITORENTER);

				String fieldname = synchronizedMethod.getEnclosingClass()
						.allocateField("class$");
				
				FieldGen f = new FieldGen(Modifier.STATIC | Modifier.PRIVATE, Type.getType(Class.class), fieldname,
						synchronizedMethod.getEnclosingClass().getConstantPool());

				synchronizedMethod.getEnclosingClass().addField(f, null);

				// 10: invokestatic #44; //Method
				// java/lang/Class.forName:(Ljava/lang/String;)Ljava/lang/Class;
				// 13: dup
				// 14: putstatic #59; //Field class$1:Ljava/lang/Class;
				// 17: goto 32
				// 20: new #46; //class java/lang/NoClassDefFoundError
				// 23: dup_x1
				// 24: swap
				// 25: invokevirtual #52; //Method
				// java/lang/Throwable.getMessage:()Ljava/lang/String;
				// 28: invokespecial #54; //Method
				// java/lang/NoClassDefFoundError."<init>":(Ljava/lang/String;)V
				// 31: athrow
				prepend.append(fact.createGetStatic("C", fieldname, Type
						.getType(Class.class)));
				prepend.append(InstructionFactory.createDup(1));
				prepend.append(InstructionFactory.createBranchInstruction(
						Constants.IFNONNULL, parttwo.getStart()));
				prepend.append(InstructionFactory.POP);

				prepend.append(fact.createConstant("C"));
				InstructionHandle tryInstruction = prepend.getEnd();
				prepend.append(fact.createInvoke("java.lang.Class", "forName",
						clazzType, new Type[] { Type.getType(String.class) },
						Constants.INVOKESTATIC));
				InstructionHandle catchInstruction = prepend.getEnd();
				prepend.append(InstructionFactory.createDup(1));

				prepend.append(fact.createPutStatic(synchronizedMethod
						.getEnclosingClass().getType().getName(), fieldname,
						Type.getType(Class.class)));
				prepend.append(InstructionFactory.createBranchInstruction(
						Constants.GOTO, parttwo.getStart()));

				// start of catch block
				InstructionList catchBlockForLiteralLoadingFail = new InstructionList();
				catchBlockForLiteralLoadingFail.append(fact
						.createNew((ObjectType) Type
								.getType(NoClassDefFoundError.class)));
				catchBlockForLiteralLoadingFail.append(InstructionFactory
						.createDup_1(1));
				catchBlockForLiteralLoadingFail.append(InstructionFactory.SWAP);
				catchBlockForLiteralLoadingFail.append(fact.createInvoke(
						"java.lang.Throwable", "getMessage", Type
								.getType(String.class), new Type[] {},
						Constants.INVOKEVIRTUAL));
				catchBlockForLiteralLoadingFail.append(fact.createInvoke(
						"java.lang.NoClassDefFoundError", "<init>", Type.VOID,
						new Type[] { Type.getType(String.class) },
						Constants.INVOKESPECIAL));
				catchBlockForLiteralLoadingFail
						.append(InstructionFactory.ATHROW);
				InstructionHandle catchBlockStart = catchBlockForLiteralLoadingFail
						.getStart();
				prepend.append(catchBlockForLiteralLoadingFail);
				prepend.append(parttwo);
				// MONITORENTER
				// pseudocode: load up 'this' (var0), dup it, store it in a new
				// local var (for use with monitorexit) and call monitorenter:
				// ALOAD_0, DUP, ASTORE_<n>, MONITORENTER
				// prepend.append(InstructionFactory.createLoad(classType,0));
				// prepend.append(InstructionFactory.createDup(1));
				// int slotForThis =
				// synchronizedMethod.allocateLocal(classType);
				// prepend.append(InstructionFactory.createStore(classType,
				// slotForThis));
				// prepend.append(InstructionFactory.MONITORENTER);

				// MONITOREXIT
				// here be dragons

				// We basically need to wrap the code from the method in a
				// finally block that
				// will ensure monitorexit is called. Content on the finally
				// block seems to
				// be always:
				// 
				// E1: ALOAD_1
				// MONITOREXIT
				// ATHROW
				//
				// so lets build that:
				InstructionList finallyBlock = new InstructionList();
				finallyBlock.append(InstructionFactory.createLoad(Type
						.getType(java.lang.Class.class), slotForThis));
				finallyBlock.append(InstructionConstants.MONITOREXIT);
				finallyBlock.append(InstructionConstants.ATHROW);

				// finally -> E1
				// | GETSTATIC java.lang.System.out Ljava/io/PrintStream; (line
				// 21)
				// | LDC "hello"
				// | INVOKEVIRTUAL java.io.PrintStream.println
				// (Ljava/lang/String;)V
				// | ALOAD_1 (line 20)
				// | MONITOREXIT
				// finally -> E1
				// GOTO L0
				// finally -> E1
				// | E1: ALOAD_1
				// | MONITOREXIT
				// finally -> E1
				// ATHROW
				// L0: RETURN (line 23)
				// frameEnv.put(donorFramePos, thisSlot);

				// search for 'returns' and make them to the
				// aload_<n>,monitorexit
				InstructionHandle walker = body.getStart();
				List rets = new ArrayList();
				while (walker != null) { // !walker.equals(body.getEnd())) {
					if (walker.getInstruction().isReturnInstruction()) {
						rets.add(walker);
					}
					walker = walker.getNext();
				}
				if (rets.size() > 0) {
					// need to ensure targeters for 'return' now instead target
					// the load instruction
					// (so we never jump over the monitorexit logic)

					for (Iterator iter = rets.iterator(); iter.hasNext();) {
						InstructionHandle element = (InstructionHandle) iter
								.next();
						// System.err.println("Adding monitor exit block at
						// "+element);
						InstructionList monitorExitBlock = new InstructionList();
						monitorExitBlock.append(InstructionFactory.createLoad(
								classType, slotForThis));
						monitorExitBlock
								.append(InstructionConstants.MONITOREXIT);
						// monitorExitBlock.append(Utility.copyInstruction(element.getInstruction()));
						// element.setInstruction(InstructionFactory.createLoad(classType,slotForThis));
						InstructionHandle monitorExitBlockStart = body.insert(
								element, monitorExitBlock);

						// now move the targeters from the RET to the start of
						// the monitorexit block
						InstructionTargeter[] targeters = element
								.getTargeters().toArray(new InstructionTargeter[0]);
						if (targeters != null) {
							for (int i = 0; i < targeters.length; i++) {

								InstructionTargeter targeter = targeters[i];
								// what kinds are there?
								if (targeter instanceof LocalVariableTag) {
									// ignore
								} else if (targeter instanceof LineNumberTag) {
									// ignore
								//} else if (targeter instanceof GOTO
								//		|| targeter instanceof GOTO_W) {
									//// move it...
							//		targeter.updateTarget(element,
								//			monitorExitBlockStart);
								} else if (targeter instanceof InstructionBranch) {
									// move it
									targeter.updateTarget(element,
											monitorExitBlockStart);
								} else {
									throw new RuntimeException(
											"Unexpected targeter encountered during transform: "
													+ targeter);
								}
							}
						}
					}
				}
				// body =
				// rewriteWithMonitorExitCalls(body,fact,true,slotForThis,classType);
				// synchronizedMethod.setBody(body);

				// now the magic, putting the finally block around the code
				InstructionHandle finallyStart = finallyBlock.getStart();

				InstructionHandle tryPosition = body.getStart();
				InstructionHandle catchPosition = body.getEnd();
				body.insert(body.getStart(), prepend); // now we can put the
				// monitorenter stuff on

				synchronizedMethod.getBody().append(finallyBlock);
				synchronizedMethod.addExceptionHandler(tryPosition,
						catchPosition, finallyStart, null/* ==finally */,
						false);
				synchronizedMethod.addExceptionHandler(tryInstruction,
						catchInstruction, catchBlockStart, (ObjectType) Type
								.getType(ClassNotFoundException.class), true);
				synchronizedMethod.addExceptionHandler(finallyStart,
						finallyStart.getNext(), finallyStart, null, false);
			}
		} else {

			// TRANSFORMING NON STATIC METHOD
			Type classType = BcelWorld.makeBcelType(synchronizedMethod
					.getEnclosingClass().getType());
			// MONITORENTER
			// pseudocode: load up 'this' (var0), dup it, store it in a new
			// local var (for use with monitorexit) and call monitorenter:
			// ALOAD_0, DUP, ASTORE_<n>, MONITORENTER
			prepend.append(InstructionFactory.createLoad(classType, 0));
			prepend.append(InstructionFactory.createDup(1));
			int slotForThis = synchronizedMethod.allocateLocal(classType);
			prepend.append(InstructionFactory.createStore(classType,
					slotForThis));
			prepend.append(InstructionFactory.MONITORENTER);
			// body.insert(body.getStart(),prepend);

			// MONITOREXIT

			// We basically need to wrap the code from the method in a finally
			// block that
			// will ensure monitorexit is called. Content on the finally block
			// seems to
			// be always:
			// 
			// E1: ALOAD_1
			// MONITOREXIT
			// ATHROW
			//
			// so lets build that:
			InstructionList finallyBlock = new InstructionList();
			finallyBlock.append(InstructionFactory.createLoad(classType,
					slotForThis));
			finallyBlock.append(InstructionConstants.MONITOREXIT);
			finallyBlock.append(InstructionConstants.ATHROW);

			// finally -> E1
			// | GETSTATIC java.lang.System.out Ljava/io/PrintStream; (line 21)
			// | LDC "hello"
			// | INVOKEVIRTUAL java.io.PrintStream.println (Ljava/lang/String;)V
			// | ALOAD_1 (line 20)
			// | MONITOREXIT
			// finally -> E1
			// GOTO L0
			// finally -> E1
			// | E1: ALOAD_1
			// | MONITOREXIT
			// finally -> E1
			// ATHROW
			// L0: RETURN (line 23)
			// frameEnv.put(donorFramePos, thisSlot);

			// search for 'returns' and make them to the aload_<n>,monitorexit
			InstructionHandle walker = body.getStart();
			List rets = new ArrayList();
			while (walker != null) { // !walker.equals(body.getEnd())) {
				if (walker.getInstruction().isReturnInstruction()) {
					rets.add(walker);
				}
				walker = walker.getNext();
			}
			if (rets.size() > 0) {
				// need to ensure targeters for 'return' now instead target the
				// load instruction
				// (so we never jump over the monitorexit logic)

				for (Iterator iter = rets.iterator(); iter.hasNext();) {
					InstructionHandle element = (InstructionHandle) iter.next();
					// System.err.println("Adding monitor exit block at
					// "+element);
					InstructionList monitorExitBlock = new InstructionList();
					monitorExitBlock.append(InstructionFactory.createLoad(
							classType, slotForThis));
					monitorExitBlock.append(InstructionConstants.MONITOREXIT);
					// monitorExitBlock.append(Utility.copyInstruction(element.getInstruction()));
					// element.setInstruction(InstructionFactory.createLoad(classType,slotForThis));
					InstructionHandle monitorExitBlockStart = body.insert(
							element, monitorExitBlock);

					// now move the targeters from the RET to the start of the
					// monitorexit block
					InstructionTargeter[] targeters = element.getTargeters().toArray(new InstructionTargeter[0]);
					if (targeters != null) {
						for (int i = 0; i < targeters.length; i++) {

							InstructionTargeter targeter = targeters[i];
							// what kinds are there?
							if (targeter instanceof LocalVariableTag) {
								// ignore
							} else if (targeter instanceof LineNumberTag) {
								// ignore
							//} else if (targeter instanceof GOTO
							//		|| targeter instanceof GOTO_W) {
							//	// move it...
						//		targeter.updateTarget(element,
							//			monitorExitBlockStart);
							} else if (targeter instanceof InstructionBranch) {
								// move it
								targeter.updateTarget(element,
										monitorExitBlockStart);
							} else {
								throw new RuntimeException(
										"Unexpected targeter encountered during transform: "
												+ targeter);
							}
						}
					}
				}
			}

			// now the magic, putting the finally block around the code
			InstructionHandle finallyStart = finallyBlock.getStart();

			InstructionHandle tryPosition = body.getStart();
			InstructionHandle catchPosition = body.getEnd();
			body.insert(body.getStart(), prepend); // now we can put the
			// monitorenter stuff on
			synchronizedMethod.getBody().append(finallyBlock);
			synchronizedMethod.addExceptionHandler(tryPosition, catchPosition,
					finallyStart, null/* ==finally */, false);
			synchronizedMethod.addExceptionHandler(finallyStart, finallyStart
					.getNext(), finallyStart, null, false);
			// also the exception handling for the finally block jumps to itself

			// max locals will already have been modified in the allocateLocal()
			// call

			// synchronized bit is removed on LazyMethodGen.pack()
		}

		// gonna have to go through and change all aload_0s to load the var from
		// a variable,
		// going to add a new variable for the this var

	}
	private boolean inlineSelfConstructors(LazyClassGen clazz) {
		List methodGens = new ArrayList(clazz.getMethodGens());
		boolean inlinedSomething = false;
		for (Iterator i = methodGens.iterator(); i.hasNext();) {
			LazyMethodGen mg = (LazyMethodGen) i.next();
			if (!mg.getName().equals("<init>"))
				continue;
			InstructionHandle ih = MultiMechanism.findSuperOrThisCall(mg);
			if (ih != null && isThisCall(clazz, ih)) {
				LazyMethodGen donor = getCalledMethod(clazz, ih);
				inlineMethod(this, donor, mg, ih);
				inlinedSomething = true;
			}
		}
		return inlinedSomething;
	}

	private void positionAndImplement(MultiMechanism mm,
			List initializationShadows) {
		for (Iterator i = initializationShadows.iterator(); i.hasNext();) {
			BcelShadow s = (BcelShadow) i.next();
			positionInitializationShadow(mm, s);
			// s.getEnclosingMethod().print();
			mm.transform(s);
		}
	}

	/** TODO: Most of these should be moved to AJ mechanism */
	private void positionInitializationShadow(MultiMechanism mm, BcelShadow s) {
		LazyMethodGen mg = s.getEnclosingMethod();
		InstructionHandle call = MultiMechanism.findSuperOrThisCall(mg);

		InstructionList body = mg.getBody();
		ShadowRange r = new ShadowRange(body);
		r.associateWithShadow((BcelShadow) s);
		if (s.getKind() == Shadow.PreInitialization) {
			// XXX assert first instruction is an ALOAD_0.
			// a pre shadow goes from AFTER the first instruction (which we
			// believe to
			// be an ALOAD_0) to just before the call to super
			r.associateWithTargets(Range.genStart(body, body.getStart()
					.getNext()), Range.genEnd(body, call.getPrev()));
		} else {
			// assert s.getKind() == Shadow.Initialization
			r.associateWithTargets(Range.genStart(body, call.getNext()), Range
					.genEnd(body));
		}
		// keeps method-to-shadow relations up-to-date
		mm.addMethodShadow(mg, s);
	}

	private boolean isThisCall(LazyClassGen clazz, InstructionHandle ih) {
		ConstantPool cpg = clazz.getConstantPool();
		InvokeInstruction inst = (InvokeInstruction) ih.getInstruction();
		return inst.getClassName(cpg).equals(clazz.getName());
	}

	/**
	 * get a called method: Assumes the called method is in this class, and the
	 * reference to it is exact (a la INVOKESPECIAL).
	 * 
	 * @param ih
	 *            The InvokeInstruction instructionHandle pointing to the called
	 *            method.
	 */
	private LazyMethodGen getCalledMethod(LazyClassGen clazz,
			InstructionHandle ih) {
		ConstantPool cpg = clazz.getConstantPool();
		InvokeInstruction inst = (InvokeInstruction) ih.getInstruction();

		String methodName = inst.getName(cpg);
		String signature = inst.getSignature(cpg);

		return clazz.getLazyMethodGen(methodName, signature);
	}

	private void addAspectsAffectingType(MultiMechanism mm, LazyClassGen clazz) {
		if (!(BcelClassWeaver.inReweavableMode || clazz.getType().isAspect()))
			return;
		for (Iterator i = clazz.getMethodGens().iterator(); i.hasNext();) {
			LazyMethodGen mg = (LazyMethodGen) i.next();
			List<BcelShadow> matchedShadows = mm.getMethodShadows(mg);
			if (!mg.hasBody() || matchedShadows == null
					|| matchedShadows.size() == 0)
				continue;
			// For matching mungers, add their declaring aspects to the list
			// that affected this type
			if (BcelClassWeaver.inReweavableMode || clazz.getType().isAspect())
				itdWeaver.getAspectsAffectingType().addAll(
						findAspectsForMungers(matchedShadows, mg));
		}
	}

	private Set findAspectsForMungers(List<BcelShadow> matchedShadows,
			LazyMethodGen mg) {
		Set aspectsAffectingType = new HashSet();
		for (Iterator iter = matchedShadows.iterator(); iter.hasNext();) {
			BcelShadow aShadow = (BcelShadow) iter.next();
			// Mungers in effect on that shadow
			List<ShadowMunger> matchingMungers = getShadowMungers(aShadow);
			if (matchingMungers == null)
				return aspectsAffectingType;
			for (ShadowMunger aMunger : getShadowMungers(aShadow)) {
				// Iterator iter2 =
				// aShadow.getMungers().iterator();iter2.hasNext();) {
				// ShadowMunger aMunger = (ShadowMunger) iter2.next();
				if (aMunger instanceof BcelAdvice) {
					BcelAdvice bAdvice = (BcelAdvice) aMunger;
					if (bAdvice.getConcreteAspect() != null) {
						aspectsAffectingType.add(bAdvice.getConcreteAspect()
								.getName());
					}
				} else {
					// It is a 'Checker' - we don't need to remember aspects
					// that only contributed Checkers...
				}
			}
		}
		return aspectsAffectingType;
	}

	private boolean isSpecial(LazyMethodGen mg) {
		return mg.hasBody()
				&& (mg.getName().startsWith("ajc$interFieldInit")
						|| mg.isAdviceMethod() || !shouldWeaveBody(mg));
	}

	private boolean shouldWeaveBody(LazyMethodGen mg) {
		return !(mg.isBridgeMethod()
				|| (mg.isAjSynthetic() && !mg.getName().equals("<clinit>")) || (mg
				.getEffectiveSignature() != null && !mg.getEffectiveSignature()
				.isWeaveBody()));
	}

	// =========================================

	protected void addAssociation(BcelShadow shadow, ShadowMunger munger) {
		// the associations between mungers and shadows should be external.
		// shadow.addMunger(munger);
		List<ShadowMunger> mungers = shadowMungers.get(shadow);
		if (mungers == null) {
			mungers = new ArrayList<ShadowMunger>();
			shadowMungers.put(shadow, mungers);
		}
		mungers.add(munger);
	}

	/**
	 * generate the instructions to be inlined.
	 * 
	 * @param donor
	 *            the method from which we will copy (and adjust frame and
	 *            jumps) instructions.
	 * @param recipient
	 *            the method the instructions will go into. Used to get the
	 *            frame size so we can allocate new frame locations for locals
	 *            in donor.
	 * @param frameEnv
	 *            an environment to map from donor frame to recipient frame,
	 *            initially populated with argument locations.
	 * @param fact
	 *            an instruction factory for recipient
	 */
	static InstructionList genInlineInstructions(AJWeaver AJM,
			LazyMethodGen donor, LazyMethodGen recipient, IntMap frameEnv,
			InstructionFactory fact, boolean keepReturns) {
		InstructionList footer = new InstructionList();
		InstructionHandle end = footer.append(InstructionConstants.NOP);

		InstructionList ret = new InstructionList();
		InstructionList sourceList = donor.getBody();

		Map srcToDest = new HashMap();
		ConstantPool donorCpg = donor.getEnclosingClass()
				.getConstantPool();
		ConstantPool recipientCpg = recipient.getEnclosingClass()
				.getConstantPool();

		boolean isAcrossClass = donorCpg != recipientCpg;

		// first pass: copy the instructions directly, populate the srcToDest
		// map,
		// fix frame instructions
		for (InstructionHandle src = sourceList.getStart(); src != null; src = src
				.getNext()) {
			Instruction fresh = Utility.copyInstruction(src.getInstruction());
			InstructionHandle dest;
			if (fresh instanceof InstructionCP) {
				// need to reset index to go to new constant pool. This is
				// totally
				// a computation leak... we're testing this LOTS of times. Sigh.
				if (isAcrossClass) {
					InstructionCP cpi = (InstructionCP) fresh;
					cpi.setIndex(recipientCpg.addConstant(donorCpg
							.getConstant(cpi.getIndex()), donorCpg));
				}
			}
			if (src.getInstruction() == Range.RANGEINSTRUCTION) {
				dest = ret.append(Range.RANGEINSTRUCTION);
			} else if (fresh.isReturnInstruction()) {
				if (keepReturns) {
					dest = ret.append(fresh);
				} else {
					dest = ret.append(InstructionFactory
							.createBranchInstruction(Constants.GOTO, end));
				}
			} else if (fresh instanceof InstructionBranch) {
				dest = ret.append((InstructionBranch) fresh);
			} else if (fresh.isLocalVariableInstruction() 
					|| fresh instanceof RET) {
				IndexedInstruction indexed = (IndexedInstruction) fresh;
				int oldIndex = indexed.getIndex();
				int freshIndex;
				if (!frameEnv.hasKey(oldIndex)) {
					freshIndex = recipient.allocateLocal(2);
					frameEnv.put(oldIndex, freshIndex);
				} else {
					freshIndex = frameEnv.get(oldIndex);
				}
				indexed.setIndex(freshIndex);
				dest = ret.append(fresh);
			} else {
				dest = ret.append(fresh);
			}
			srcToDest.put(src, dest);
		}

		// second pass: retarget branch instructions, copy ranges and tags
		Map tagMap = new HashMap();
		Map shadowMap = new HashMap();
		for (InstructionHandle dest = ret.getStart(), src = sourceList
				.getStart(); dest != null; dest = dest.getNext(), src = src
				.getNext()) {
			Instruction inst = dest.getInstruction();

			// retarget branches
			if (inst instanceof InstructionBranch) {
				InstructionBranch branch = (InstructionBranch) inst;
				InstructionHandle oldTarget = branch.getTarget();
				InstructionHandle newTarget = (InstructionHandle) srcToDest
						.get(oldTarget);
				if (newTarget == null) {
					// assert this is a GOTO
					// this was a return instruction we previously replaced
				} else {
					branch.setTarget(newTarget);
					if (branch instanceof InstructionSelect) {
						InstructionSelect select = (InstructionSelect) branch;
						InstructionHandle[] oldTargets = select.getTargets();
						for (int k = oldTargets.length - 1; k >= 0; k--) {
							select.setTarget(k, (InstructionHandle) srcToDest
									.get(oldTargets[k]));
						}
					}
				}
			}

			// copy over tags and range attributes
			InstructionTargeter[] srcTargeters = src.getTargeters().toArray(new InstructionTargeter[0]);
			if (srcTargeters != null) {
				for (int j = srcTargeters.length - 1; j >= 0; j--) {
					InstructionTargeter old = srcTargeters[j];
					if (old instanceof Tag) {
						Tag oldTag = (Tag) old;
						Tag fresh = (Tag) tagMap.get(oldTag);
						if (fresh == null) {
							fresh = oldTag.copy();
							tagMap.put(oldTag, fresh);
						}
						dest.addTargeter(fresh);
					} else if (old instanceof ExceptionRange) {
						ExceptionRange er = (ExceptionRange) old;
						if (er.getStart() == src) {
							ExceptionRange freshEr = new ExceptionRange(
									recipient.getBody(), er.getCatchType(), er
											.getPriority());
							freshEr.associateWithTargets(dest,
									(InstructionHandle) srcToDest.get(er
											.getEnd()),
									(InstructionHandle) srcToDest.get(er
											.getHandler()));
						}
					} else if (old instanceof ShadowRange) {
						// DO we use it anywhere anyway?
						ShadowRange oldRange = (ShadowRange) old;
						if (oldRange.getStart() == src) {
							BcelShadow oldShadow = oldRange.getShadow();
							BcelShadow freshEnclosing = oldShadow
									.getEnclosingShadow() == null ? null
									: (BcelShadow) shadowMap.get(oldShadow
											.getEnclosingShadow());

							List<ShadowMunger> oldMungers = AJM
									.getShadowMungers(oldShadow);
							BcelShadow freshShadow = oldShadow.copyInto(
									recipient, freshEnclosing);
							List<ShadowMunger> freshMungers = new ArrayList<ShadowMunger>();
							for (ShadowMunger munger : oldMungers)
								AJM.addAssociation(freshShadow, munger);

							ShadowRange freshRange = new ShadowRange(
									recipient.getBody());
							freshRange.associateWithShadow(freshShadow);
							freshRange.associateWithTargets(dest,
									(InstructionHandle) srcToDest.get(oldRange
											.getEnd()));
							shadowMap.put(oldRange, freshRange);
							// recipient.matchedShadows.add(freshShadow);
							// XXX should go through the NEW copied shadow and
							// update
							// the thisVar, targetVar, and argsVar
							// ??? Might want to also go through at this time
							// and add
							// "extra" vars to the shadow.
						}
					}
				}
			}
		}
		if (!keepReturns)
			ret.append(footer);
		return ret;
	}

	/**
	 * generate the argument stores in preparation for inlining.
	 * 
	 * @param donor
	 *            the method we will inline from. Used to get the signature.
	 * @param recipient
	 *            the method we will inline into. Used to get the frame size so
	 *            we can allocate fresh locations.
	 * @param frameEnv
	 *            an empty environment we populate with a map from donor frame
	 *            to recipient frame.
	 * @param fact
	 *            an instruction factory for recipient
	 */
	private static InstructionList genArgumentStores(LazyMethodGen donor,
			LazyMethodGen recipient, IntMap frameEnv, InstructionFactory fact) {
		InstructionList ret = new InstructionList();

		int donorFramePos = 0;

		// writing ret back to front because we're popping.
		if (!donor.isStatic()) {
			int targetSlot = recipient.allocateLocal(Type.OBJECT);
			ret.insert(InstructionFactory.createStore(Type.OBJECT, targetSlot));
			frameEnv.put(donorFramePos, targetSlot);
			donorFramePos += 1;
		}
		Type[] argTypes = donor.getArgumentTypes();
		for (int i = 0, len = argTypes.length; i < len; i++) {
			Type argType = argTypes[i];
			int argSlot = recipient.allocateLocal(argType);
			ret.insert(InstructionFactory.createStore(argType, argSlot));
			frameEnv.put(donorFramePos, argSlot);
			donorFramePos += argType.getSize();
		}
		return ret;
	}

	/**
	 * inline a particular call in bytecode.
	 * 
	 * @param donor
	 *            the method we want to inline
	 * @param recipient
	 *            the method containing the call we want to inline
	 * @param call
	 *            the instructionHandle in recipient's body holding the call we
	 *            want to inline.
	 */
	public static void inlineMethod(AJWeaver AJM, LazyMethodGen donor,
			LazyMethodGen recipient, InstructionHandle call) {
		// assert recipient.contains(call)

		/*
		 * Implementation notes:
		 * 
		 * We allocate two slots for every tempvar so we don't screw up longs
		 * and doubles which may share space. This could be conservatively
		 * avoided (no reference to a long/double instruction, don't do it) or
		 * packed later. Right now we don't bother to pack.
		 * 
		 * Allocate a new var for each formal param of the inlined. Fill with
		 * stack contents. Then copy the inlined instructions in with the
		 * appropriate remap table. Any framelocs used by locals in inlined are
		 * reallocated to top of frame,
		 */
		final InstructionFactory fact = recipient.getEnclosingClass()
				.getFactory();

		IntMap frameEnv = new IntMap();

		// this also sets up the initial environment
		InstructionList argumentStores = genArgumentStores(donor, recipient,
				frameEnv, fact);

		InstructionList inlineInstructions = genInlineInstructions(AJM, donor,
				recipient, frameEnv, fact, false);

		inlineInstructions.insert(argumentStores);

		recipient.getBody().append(call, inlineInstructions);
		Utility.deleteInstruction(call, recipient);
	}

}
