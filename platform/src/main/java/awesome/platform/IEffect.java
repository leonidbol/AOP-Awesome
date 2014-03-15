package awesome.platform;
import org.aspectj.weaver.*;
import org.aspectj.weaver.bcel.BcelShadow;

public interface IEffect {

	public void transform(BcelShadow shadow);
	
	public void specializeOn(Shadow shadow);
	
}
