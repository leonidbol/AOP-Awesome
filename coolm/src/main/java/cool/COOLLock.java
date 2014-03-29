package cool;
import java.lang.annotation.*;

@Retention(RetentionPolicy.CLASS)
@Target(ElementType.METHOD)
public @interface COOLLock {
	   String methodName();
	   String[] parameterTypes();
	   String className();
}
