package cool;

import java.util.List;
import java.util.ArrayList;

public class MethodState {

	private List<Thread> threads = new ArrayList<Thread>();

	public synchronized void in() {
		threads.add(Thread.currentThread());
	}

	public synchronized void out() {
		threads.remove(Thread.currentThread());
	}

	/**
	 * 
	 * @return true if the method is currently being executed by other threads,
	 *         and is not executed by this thread. false, if the method is
	 *         executed by no thread, or if this method is executed by several
	 *         threads, including the current one.
	 */
	public synchronized boolean isBusyByOtherThread() {
		return (!isFree() && !threads.contains(Thread.currentThread()));
		/*
		 * Thread currentThread = Thread.currentThread(); for (Thread t:threads)
		 * if (t!=currentThread) return true; return false;
		 */
	}

	/**
	 * 
	 * @return true, if no thread is executing this method.
	 */
	public synchronized boolean isFree() {
		return threads.size()==0;
	}
}
