package cool;
import java.lang.annotation.*;

@Retention(RetentionPolicy.CLASS)
@Target(ElementType.METHOD)
public @interface COOLRequires {
	   String methodName();
	   String[] parameterTypes();
	   String className();
}
