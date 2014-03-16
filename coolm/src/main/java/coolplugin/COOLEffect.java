package coolplugin;

import java.lang.reflect.Modifier;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;

import org.aspectj.weaver.*;
import org.aspectj.weaver.bcel.BcelShadow;
import org.aspectj.weaver.bcel.BcelVar;
import org.aspectj.weaver.bcel.BcelWorld;
import org.aspectj.weaver.bcel.Range;
import org.aspectj.weaver.bcel.ShadowRange;

import org.aspectj.weaver.bcel.Utility;
import org.aspectj.apache.bcel.Constants;
import org.aspectj.apache.bcel.generic.*;

import awesome.platform.IEffect;


public abstract class COOLEffect implements IEffect {	
	
	protected abstract InstructionList 
	  getAdviceInstructions(BcelShadow shadow);
	
	protected void weaveBefore(BcelShadow shadow) {
	    shadow.getRange().insert(
		        getAdviceInstructions(shadow), 
		        Range.InsideBefore);
	}
	
	protected void weaveAfterReturning(BcelShadow shadow) {
	    List returns = findReturnInstructions(shadow);
	    boolean hasReturnInstructions = !returns.isEmpty();
	    
	    // list of instructions that handle the actual return from the join point
	    InstructionList retList = new InstructionList();
	            
	    // variable that holds the return value
	    BcelVar returnValueVar = null;
	    
	    if (hasReturnInstructions) {
	    	returnValueVar = generateReturnInstructions(shadow, returns,retList);
	    } else  {
	    	// we need at least one instruction, as the target for jumps
	        retList.append(InstructionConstants.NOP);            
	    }
	
	    // list of instructions for dispatching to the advice itself
	    InstructionList advice = getAdviceInstructions(shadow);            
	    
	    if (hasReturnInstructions) {
	        InstructionHandle gotoTarget = advice.getStart();           
			for (Iterator i = returns.iterator(); i.hasNext();) {
				InstructionHandle ih = (InstructionHandle) i.next();
				retargetReturnInstruction(shadow, returnValueVar, gotoTarget, ih);
			}
	    }            
	     
	    shadow.getRange().append(advice);
	    shadow.getRange().append(retList);
	}
	
	protected void weaveAfterThrowing(BcelShadow shadow, UnresolvedType catchType) {
		// a good optimization would be not to generate anything here
		// if the shadow is GUARANTEED empty (i.e., there's NOTHING, not even
		// a shadow, inside me).
		if (shadow.getRange().getStart().getNext() == shadow.getRange().getEnd()) return;
	    InstructionFactory fact = shadow.getFactory();        
	    InstructionList handler = new InstructionList();        
	    BcelVar exceptionVar = shadow.genTempVar(catchType);
	    exceptionVar.appendStore(handler, fact);
   
	    InstructionList endHandler = new InstructionList(
	        exceptionVar.createLoad(fact));
	    handler.append(getAdviceInstructions(shadow));
	    handler.append(endHandler);
	    handler.append(InstructionConstants.ATHROW);        
	    InstructionHandle handlerStart = handler.getStart();
	                                
	    if (shadow.isFallsThrough()) {
	        InstructionHandle jumpTarget = handler.append(InstructionConstants.NOP);
	        handler.insert(InstructionFactory.createBranchInstruction(Constants.GOTO, jumpTarget));
	    }
		InstructionHandle protectedEnd = handler.getStart();
	    shadow.getRange().insert(handler, Range.InsideAfter);       
	    shadow.getEnclosingMethod().addExceptionHandler(shadow.getRange().getStart().getNext(), protectedEnd.getPrev(),
	                             handlerStart, (ObjectType)BcelWorld.makeBcelType(catchType), //???Type.THROWABLE, 
	                             // high priority if our args are on the stack
	                             shadow.getKind().hasHighPriorityExceptions());
	}
	
	
	private void retargetReturnInstruction(BcelShadow shadow, BcelVar returnValueVar, InstructionHandle gotoTarget, InstructionHandle returnHandle) {
		// pr148007, work around JRockit bug
		// replace ret with store into returnValueVar, followed by goto if not
		// at the end of the instruction list...
		InstructionList newInstructions = new InstructionList();
		if (returnValueVar != null) {
			// store the return value into this var
			returnValueVar.appendStore(newInstructions, shadow.getFactory());
		}
		if (!isLastInstructionInRange(returnHandle,shadow.getRange())) {
			newInstructions.append(InstructionFactory.createBranchInstruction(
					Constants.GOTO,
					gotoTarget));
		}
		if (newInstructions.isEmpty()) {
			newInstructions.append(InstructionConstants.NOP);
		}
		Utility.replaceInstruction(returnHandle,newInstructions,shadow.getEnclosingMethod());
	}
	
    private boolean isLastInstructionInRange(InstructionHandle ih, ShadowRange aRange) {
    	return ih.getNext() == aRange.getEnd();
    }
	
    /**
	 * @return a list of all the return instructions in the range of this shadow
	 */
	private List findReturnInstructions(BcelShadow shadow) {
		ShadowRange range = shadow.getRange();
		List returns = new ArrayList();
        for (InstructionHandle ih = range.getStart(); ih != range.getEnd(); ih = ih.getNext()) {
            if (ih.getInstruction().isReturnInstruction()) {
                returns.add(ih);
            }
        }
		return returns;
	}

	
	/**
	 * Given a list containing all the return instruction handles for this shadow,
	 * finds the last return instruction and copies it, making this the ultimate
	 * return. If the shadow has a non-void return type, we also create a temporary
	 * variable to hold the return value, and load the value from this var before
	 * returning (see pr148007 for why we do this - it works around a JRockit bug,
	 * and is also closer to what javac generates)
	 * @param returns list of all the return instructions in the shadow
	 * @param returnInstructions instruction list into which the return instructions should
	 * be generated
	 * @return the variable holding the return value, if needed
	 */
	private BcelVar generateReturnInstructions(BcelShadow shadow, List returns, InstructionList returnInstructions) {
		BcelVar returnValueVar = null;
    	InstructionHandle lastReturnHandle = (InstructionHandle)returns.get(returns.size() - 1);
    	Instruction newReturnInstruction = Utility.copyInstruction(lastReturnHandle.getInstruction());
    	if (!shadow.getReturnType().equals(ResolvedType.VOID)) {
        	returnValueVar = shadow.genTempVar(shadow.getReturnType());
            returnValueVar.appendLoad(returnInstructions,shadow.getFactory());
    	} else {
    		returnInstructions.append(newReturnInstruction);
    	}
    	returnInstructions.append(newReturnInstruction);
    	return returnValueVar;
	}
	

}
