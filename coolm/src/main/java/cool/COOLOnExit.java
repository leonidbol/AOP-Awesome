package cool.runtime;
import java.lang.annotation.*;

@Retention(RetentionPolicy.CLASS)
@Target(ElementType.METHOD)
public @interface COOLOnExit {
	   String methodName();
	   String[] parameterTypes();
	   String className();
}