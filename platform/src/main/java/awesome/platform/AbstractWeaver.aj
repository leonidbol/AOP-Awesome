package awesome.platform;
import org.aspectj.apache.bcel.generic.InstructionList;
import org.aspectj.apache.bcel.generic.InstructionHandle;
import org.aspectj.weaver.IClassFileProvider;
import org.aspectj.weaver.bcel.LazyClassGen;
import org.aspectj.weaver.bcel.LazyMethodGen;
import org.aspectj.weaver.bcel.BcelWorld;
import org.aspectj.weaver.bcel.BcelShadow;

public abstract aspect AbstractWeaver implements IMechanism {
	protected MultiMechanism mm;

	protected BcelWorld world;
	
	protected IClassFileProvider inputClasses;

	after(MultiMechanism mm) : initialization(MultiMechanism.new(..)) && this(mm) {
		System.out.println("found mechanism: "+this);
		mm.addMechanism(this);
		this.mm = mm;
		this.world = mm.getWorld();
	}

	protected pointcut transformClass(MultiMechanism mm, LazyClassGen clazz): 
			execution(boolean MultiMechanism.transform(LazyClassGen)) &&
			this(mm) && args(clazz);

	protected pointcut reifyClass(MultiMechanism mm, LazyClassGen clazz): 
			execution(* MultiMechanism.reify(LazyClassGen)) &&
			this(mm) && args(clazz);

	protected pointcut reifyMethod(MultiMechanism mm, LazyMethodGen mg): 
			execution(* MultiMechanism.reify(LazyMethodGen)) &&
			this(mm) && args(mg);

	protected pointcut reifyIL(MultiMechanism mm, InstructionList il,
			LazyMethodGen mg, BcelShadow encl): 
			execution(* MultiMechanism.reify(InstructionList, LazyMethodGen, BcelShadow)) &&
			this(mm) && args(il, mg, encl);

	protected pointcut reifyInstr(MultiMechanism mm, InstructionHandle ih,
			LazyMethodGen mg, BcelShadow encl): 
			execution(* MultiMechanism.reify(InstructionHandle, LazyMethodGen, BcelShadow)) &&
			this(mm) && args(ih, mg, encl);
	
	public void setInputFiles(IClassFileProvider inputClasses) {
		this.inputClasses=inputClasses;
	}
}
