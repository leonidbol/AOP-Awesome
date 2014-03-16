package cool.runtime;
import java.lang.annotation.*;

@Retention(RetentionPolicy.CLASS)
@Target(ElementType.METHOD)
public @interface COOLUnlock {
	   String methodName();
	   String[] parameterTypes();
	   String className();
}