/**
 * The thread module provides support for thread creation and management.
 *
 * Copyright: Copyright (C) 2005-2006 Sean Kelly.  All rights reserved.
 * License:   BSD style: $(LICENSE)
 * Authors:   Sean Kelly
 */
module tango.core.Thread;


// this should be true for most architectures
version = StackGrowsDown;


public
{
    import tango.core.Type : Interval;
}
private
{
    import tango.core.Exception;


    //
    // exposed by compiler runtime
    //
    extern (C) void* cr_stackBottom();
    extern (C) void* cr_stackTop();


    void* getStackBottom()
    {
        return cr_stackBottom();
    }


    void* getStackTop()
    {
        version( D_InlineAsm_X86 )
        {
            asm
            {
                naked;
                mov EAX, ESP;
                ret;
            }
        }
        else
        {
            return cr_stackTop();
        }
    }
}


////////////////////////////////////////////////////////////////////////////////
// Thread Entry Point and Signal Handlers
////////////////////////////////////////////////////////////////////////////////


version( Win32 )
{
    private
    {
        import tango.sys.win32.Macros;
        import tango.sys.win32.UserGdi;

        const DWORD TLS_OUT_OF_INDEXES  = 0xFFFFFFFF;

        //
        // avoid multiple imports via tango.sys.windows.process
        //
        extern (Windows) alias uint function(void*) btex_fptr;

        version( X86 )
        {
            extern (C) ulong _beginthreadex(void*, uint, btex_fptr, void*, uint, uint*);
        }
        else
        {
            extern (C) uint _beginthreadex(void*, uint, btex_fptr, void*, uint, uint*);
        }


        //
        // entry point for Windows threads
        //
        extern (Windows) uint thread_entryPoint( void* arg )
        {
            Thread  obj = cast(Thread) arg;
            assert( obj );
            scope( exit ) Thread.remove( obj );

            obj.m_main.bstack = getStackBottom();
            obj.m_main.tstack = obj.m_main.bstack;
            assert( obj.m_curr == &obj.m_main );
            Thread.add( &obj.m_main );
            Thread.setThis( obj );

            // NOTE: No GC allocations may occur until the stack pointers have
            //       been set and Thread.getThis returns a valid reference to
            //       this thread object (this latter condition is not strictly
            //       necessary on Win32 but it should be followed for the sake
            //       of consistency).

            // TODO: Consider putting an auto exception object here (using
            //       alloca) forOutOfMemoryError plus something to track
            //       whether an exception is in-flight?

            try
            {
                obj.run();
            }
            catch( Object o )
            {
                obj.m_unhandled = o;
            }
            return 0;
        }


        //
        // copy of the same-named function in phobos.std.thread--it uses the
        // Windows naming convention to be consistent with GetCurrentThreadId
        //
        HANDLE GetCurrentThreadHandle()
        {
            const uint DUPLICATE_SAME_ACCESS = 0x00000002;

            HANDLE curr = GetCurrentThread(),
                   proc = GetCurrentProcess(),
                   hndl;

            DuplicateHandle( proc, curr, proc, &hndl, 0, TRUE, DUPLICATE_SAME_ACCESS );
            return hndl;
        }
    }
}
else version( Posix )
{
    private
    {
        import tango.stdc.posix.semaphore;
        import tango.stdc.posix.pthread;
        import tango.stdc.posix.signal;
        import tango.stdc.posix.unistd;
        import tango.stdc.posix.time;

        version( GNU )
        {
            import gcc.builtins;
        }


        //
        // entry point for POSIX threads
        //
        extern (C) void* thread_entryPoint( void* arg )
        {
            Thread  obj = cast(Thread) arg;
            assert( obj );
            scope( exit )
            {
                // NOTE: isRunning should be set to false after the thread is
                //       removed or a double-removal could occur between this
                //       function and thread_suspendAll.
                Thread.remove( obj );
                obj.m_isRunning = false;
            }

            static extern (C) void thread_cleanupHandler( void* arg )
            {
                Thread  obj = cast(Thread) arg;
                assert( obj );

                // NOTE: If the thread terminated abnormally, just set it as
                //       not running and let thread_suspendAll remove it from
                //       the thread list.  This is safer and is consistent
                //       with the Windows thread code.
                obj.m_isRunning = false;
            }

            // NOTE: Using void to skip the initialization here relies on
            //       knowledge of how pthread_cleanup is implemented.  It may
            //       not be appropriate for all platforms.  However, it does
            //       avoid the need to link the pthread module.  If any
            //       implementation actually requires default initialization
            //       then pthread_cleanup should be restructured to maintain
            //       the current lack of a link dependency.
            pthread_cleanup cleanup = void;
            cleanup.push( &thread_cleanupHandler, cast(void*) obj );

            // NOTE: For some reason this does not always work for threads.
            //obj.m_main.bstack = getStackBottom();
            version( D_InlineAsm_X86 )
            {
                static void* getBasePtr()
                {
                    asm
                    {
                        naked;
                        mov EAX, EBP;
                        ret;
                    }
                }

                obj.m_main.bstack = getBasePtr();
            }
            else version( StackGrowsDown )
                obj.m_main.bstack = &obj + 1;
            else
                obj.m_main.bstack = &obj;
            obj.m_main.tstack = obj.m_main.bstack;
            assert( obj.m_curr == &obj.m_main );
            Thread.add( &obj.m_main );
            Thread.setThis( obj );

            // NOTE: No GC allocations may occur until the stack pointers have
            //       been set and Thread.getThis returns a valid reference to
            //       this thread object (this latter condition is not strictly
            //       necessary on Win32 but it should be followed for the sake
            //       of consistency).

            // TODO: Consider putting an auto exception object here (using
            //       alloca) forOutOfMemoryError plus something to track
            //       whether an exception is in-flight?

            try
            {
                obj.run();
            }
            catch( Object o )
            {
                obj.m_unhandled = o;
            }
            return null;
        }


        //
        // used to track the number of suspended threads
        //
        sem_t   suspendCount;


        extern (C) void thread_suspendHandler( int sig )
        in
        {
            assert( sig == SIGUSR1 );
        }
        body
        {
            version( D_InlineAsm_X86 )
            {
                asm
                {
                    pushad;
                }
            }
            else version( GNU )
            {
                __builtin_unwind_init();
            }
            else
            {
                static assert( false, "Architecture not supported." );
            }

            // NOTE: Since registers are being pushed and popped from the stack,
            //       any other stack data used by this function should be gone
            //       before the stack cleanup code is called below.
            {
                Thread  obj = Thread.getThis();

                // NOTE: The thread reference returned by getThis is set within
                //       the thread startup code, so it is possible that this
                //       handler may be called before the reference is set.  In
                //       this case it is safe to simply suspend and not worry
                //       about the stack pointers as the thread will not have
                //       any references to GC-managed data.
                if( obj && !obj.m_lock )
                {
                    obj.m_curr.tstack = getStackTop();
                }

                sigset_t    sigres = void;
                int         status;

                status = sigfillset( &sigres );
                assert( status == 0 );

                status = sigdelset( &sigres, SIGUSR2 );
                assert( status == 0 );

                status = sem_post( &suspendCount );
                assert( status == 0 );

                sigsuspend( &sigres );

                if( obj && !obj.m_lock )
                {
                    obj.m_curr.tstack = obj.m_curr.bstack;
                }
            }

            version( D_InlineAsm_X86 )
            {
                asm
                {
                    popad;
                }
            }
            else version( GNU )
            {
                // registers will be popped automatically
            }
            else
            {
                static assert( false, "Architecture not supported." );
            }
        }


        extern (C) void thread_resumeHandler( int sig )
        in
        {
            assert( sig == SIGUSR2 );
        }
        body
        {

        }
    }
}
else
{
    // NOTE: This is the only place threading versions are checked.  If a new
    //       version is added, the module code will need to be searched for
    //       places where version-specific code may be required.  This can be
    //       easily accomlished by searching for 'Windows' or 'Posix'.
    static assert( false, "Unknown threading implementation." );
}


////////////////////////////////////////////////////////////////////////////////
// Thread
////////////////////////////////////////////////////////////////////////////////


/**
 * This class encapsulates all threading functionality for the D
 * programming language.  As thread manipulation is a required facility
 * for garbage collection, all user threads should derive from this
 * class, and instances of this class should never be explicitly deleted.
 * A new thread may be created using either derivation or composition, as
 * in the following example.
 *
 * Example:
 * -----------------------------------------------------------------------------
 *
 * class DerivedThread : Thread
 * {
 *     this()
 *     {
 *         super( &run );
 *     }
 *
 * private :
 *     void run()
 *     {
 *         printf( "Derived thread running.\n" );
 *     }
 * }
 *
 * void threadFunc()
 * {
 *     printf( "Composed thread running.\n" );
 * }
 *
 * // create instances of each type
 * Thread derived = new DerivedThread();
 * Thread composed = new Thread( &threadFunc );
 *
 * // start both threads
 * derived.start();
 * composed.start();
 *
 * // wait for the threads to complete
 * derived.join();
 * composed.join();
 *
 * -----------------------------------------------------------------------------
 */
class Thread
{
    ////////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////////


    /**
     * Initializes a thread object which is associated with a static
     * D function.
     *
     * Params:
     *  fn = The thread function.
     *
     * In:
     *  fn must not be null.
     */
    this( void function() fn )
    in
    {
        assert( fn );
    }
    body
    {
        m_fn   = fn;
        m_call = Call.FN;
        m_curr = &m_main;
    }


    /**
     * Initializes a thread object which is associated with a dynamic
     * D function.
     *
     * Params:
     *  dg = The thread function.
     *
     * In:
     *  dg must not be null.
     */
    this( void delegate() dg )
    in
    {
        assert( dg );
    }
    body
    {
        m_dg   = dg;
        m_call = Call.DG;
        m_curr = &m_main;
    }


    /**
     * Cleans up any remaining resources used by this object.
     */
    ~this()
    {
        if( m_addr == m_addr.init )
        {
            return;
        }

        version( Win32 )
        {
            m_addr = m_addr.init;
            CloseHandle( m_hndl );
            m_hndl = m_hndl.init;
        }
        else version( Posix )
        {
            pthread_detach( m_addr );
            m_addr = m_addr.init;
        }
    }


    ////////////////////////////////////////////////////////////////////////////
    // General Actions
    ////////////////////////////////////////////////////////////////////////////


    /**
     * Starts the thread and invokes the function or delegate passed upon
     * construction.
     *
     * In:
     *  This routine may only be called once per thread instance.
     *
     * Throws:
     *  ThreadException if the thread fails to start.
     */
    final void start()
    in
    {
        assert( !next && !prev );
    }
    body
    {
        // NOTE: This operation needs to be synchronized to avoid a race
        //       condition with the GC.  Without this lock, the thread
        //       could start and allocate memory before being added to
        //       the global thread list, preventing it from being scanned
        //       and causing memory to be collected that is still in use.
        synchronized( slock )
        {
            version( Win32 )
            {
                m_hndl = cast(HANDLE) _beginthreadex( null, 0, &thread_entryPoint, cast(void*) this, 0, &m_addr );
                if( cast(size_t) m_hndl == 0 )
                    throw new ThreadException( "Error creating thread" );
            }
            else version( Posix )
            {
                m_isRunning = true;
                scope( failure ) m_isRunning = false;

                if( pthread_create( &m_addr, null, &thread_entryPoint, cast(void*) this ) != 0 )
                    throw new ThreadException( "Error creating thread" );
            }
            multiThreadedFlag = true;
            add( this );
        }
    }


    /**
     * Waits for this thread to complete.  If the thread terminated as the
     * result of an unhandled exception, this exception will be rethrown.
     *
     * Params:
     *  rethrow = Rethrow any unhandled exception which may have caused this
     *            thread to terminate.
     *
     * Throws:
     *  ThreadException if the operation fails.
     *  Any exception not handled by the joined thread.
     */
    final void join( bool rethrow = true )
    {
        version( Win32 )
        {
            if( WaitForSingleObject( m_hndl, INFINITE ) != WAIT_OBJECT_0 )
                throw new ThreadException( "Unable to join thread" );
            // NOTE: m_addr must be cleared before m_hndl is closed to avoid
            //       a race condition with isRunning.  The operation is labeled
            //       volatile to prevent compiler reordering.
            volatile m_addr = m_addr.init;
            CloseHandle( m_hndl );
            m_hndl = m_hndl.init;
        }
        else version( Posix )
        {
            if( pthread_join( m_addr, null ) != 0 )
                throw new ThreadException( "Unable to join thread" );
            // NOTE: pthread_join acts as a substitute for pthread_detach,
            //       which is normally called by the dtor.  Setting m_addr
            //       to zero ensures that pthread_detach will not be called
            //       on object destruction.
            volatile m_addr = m_addr.init;
        }
        if( rethrow && m_unhandled )
        {
            throw m_unhandled;
        }
    }


    ////////////////////////////////////////////////////////////////////////////
    // General Properties
    ////////////////////////////////////////////////////////////////////////////


    /**
     * Gets the user-readable label for this thread.
     *
     * Returns:
     *  The name of this thread.
     */
    final char[] name()
    {
        synchronized( this )
        {
            return m_name;
        }
    }


    /**
     * Sets the user-readable label for this thread.
     *
     * Params:
     *  n = The new name for this thread.
     */
    final void name( char[] n )
    {
        synchronized( this )
        {
            m_name = n.dup;
        }
    }


    /**
     * Tests whether this thread is running.
     *
     * Returns:
     *  true if the thread is running, false if not.
     */
    final bool isRunning()
    {
        if( m_addr == m_addr.init )
        {
            return false;
        }

        version( Win32 )
        {
            uint ecode = 0;
            GetExitCodeThread( m_hndl, &ecode );
            return ecode == STILL_ACTIVE;
        }
        else version( Posix )
        {
            // NOTE: It should be safe to access this value without
            //       memory barriers because word-tearing and such
            //       really isn't an issue for boolean values.
            return m_isRunning;
        }
    }


    ////////////////////////////////////////////////////////////////////////////
    // Actions on Calling Thread
    ////////////////////////////////////////////////////////////////////////////


    /**
     * Suspends the calling thread for at least the supplied time, up to a
     * maximum of (uint.max - 1) milliseconds.  If a period of less than one
     * second is interrupted by the system, this call may return early.
     * Interruptions of intervals greater than one second will be resumed, if
     * possible, until the full duration has been reached.
     *
     * Please note that garbage collection on some systems (notably POSIX
     * systems) typically involves the use of signals to coordinate "stop the
     * world" collection cycles in multithreaded programs.  In such cases, a
     * signal received by the garbage collector will interrupt the sleep
     * operation within this routine.  As described above, sleep intervals of
     * at least one second will be automatically resumed, but sub-second
     * intervals are sufficiently small that an attempt to resume may result
     * in longer than expected sleep times.  Therefore, sub-second intervals
     * will not be resumed even if prematurely interrupted.
     *
     * Params:
     *  period = The minimum duration the calling thread should be suspended,
     *           in seconds.  Sub-second durations are specified as fractional
     *           values.
     *
     * In:
     *  period must be less than (uint.max - 1) milliseconds.
     *
     * Example:
     * -------------------------------------------------------------------------
     *
     * Thread.sleep( 0.05 ); // sleep for 50 milliseconds
     * Thread.sleep( 5 );    // sleep for 5 seconds
     *
     * -------------------------------------------------------------------------
     */
    static void sleep( Interval period )
    in
    {
        assert( period * 1_000 < uint.max - 1 );
    }
    body
    {
        version( Win32 )
        {
            Sleep( cast(uint)( period * 1_000 ) );
        }
        else version( Posix )
        {
            alias tango.stdc.posix.unistd.sleep psleep;

            uint seconds = cast(uint) period;
            uint micros  = cast(uint)( (period - seconds) * 1_000_000 );

            while( seconds > 0 )
                seconds = psleep( seconds );
            if( micros > 0 )
                usleep( micros );
        }
    }


    /**
     * Suspends the calling thread until interrupted.
     */
    static void sleep()
    {
        version( Win32 )
        {
            Sleep( INFINITE );
        }
        else version( Posix )
        {
            // NOTE: Posix does not have an unbounded sleep routine, but
            //       uint.max seconds is long enough to be sufficient.
            tango.stdc.posix.unistd.sleep( uint.max );
        }
    }


    /**
     * Forces a context switch to occur away from the calling thread.
     */
    static void yield()
    {
        version( Win32 )
        {
            // NOTE: Sleep(1) is necessary because Sleep(0) does not give
            //       lower priority threads any timeslice, so looping on
            //       Sleep(0) could be resource-intensive in some cases.
            Sleep( 1 );
        }
        else version( Posix )
        {
            sched_yield();
        }
    }


    ////////////////////////////////////////////////////////////////////////////
    // Thread Accessors
    ////////////////////////////////////////////////////////////////////////////


    /**
     * Provides a reference to the calling thread.
     *
     * Returns:
     *  The thread object representing the calling thread.  The result of
     *  deleting this object is undefined.
     */
    static Thread getThis()
    {
        // NOTE: This function may not be called until thread_init has
        //       completed.  See thread_suspendAll for more information
        //       on why this might occur.
        version( Win32 )
        {
            return cast(Thread) TlsGetValue( sm_this );
        }
        else version( Posix )
        {
            return cast(Thread) pthread_getspecific( sm_this );
        }
    }


    /**
     * Provides a list of all threads currently being tracked by the system.
     *
     * Returns:
     *  An array containing references to all threads currently being
     *  tracked by the system.  The result of deleting any contained
     *  objects is undefined.
     */
    static Thread[] getAll()
    {
        synchronized( slock )
        {
            size_t   pos = 0;
            Thread[] buf = new Thread[sm_tlen];

            foreach( Thread t; Thread )
            {
                buf[pos++] = t;
            }
            return buf;
        }
    }


    /**
     * Operates on all threads currently being tracked by the system.  The
     * result of deleting any Thread object is undefined.
     *
     * Params:
     *
     * dg = The supplied code as a delegate.
     *
     * Returns:
     *  Zero if all elemented are visited, nonzero if not.
     */
    static int opApply( int delegate( inout Thread ) dg )
    {
        synchronized( slock )
        {
            int ret = 0;

            for( Thread t = sm_tbeg; t; t = t.next )
            {
                ret = dg( t );
                if( ret )
                    break;
            }
            return ret;
        }
    }


    ////////////////////////////////////////////////////////////////////////////
    // Local Storage Actions
    ////////////////////////////////////////////////////////////////////////////


    /**
     * Indicates the number of local storage pointers available at program
     * startup.  It is recommended that this number be at least 64.
     */
    const uint LOCAL_MAX = 64;


    /**
     * Reserves a local storage pointer for use and initializes this
     * location to null for all running threads.
     *
     * Returns:
     *  A key representing the array offset of this memory location.
     */
    static uint createLocal()
    {
        synchronized( slock )
        {
            foreach( uint key, inout bool set; sm_local )
            {
                if( !set )
                {
                    foreach( Thread t; sm_tbeg )
                    {
                        t.m_local[key] = null;
                    }
                    set = true;
                    return key;
                }
            }
            throw new ThreadException( "No more local storage slots available" );
        }
    }


    /**
     * Marks the supplied key as available and sets the associated location
     * to null for all running threads.  It is assumed that any key passed
     * to this function is valid.  The result of calling this function for
     * a key which is still in use is undefined.
     *
     * Params:
     *  key = The key to delete.
     */
    static void deleteLocal( uint key )
    {
        synchronized( slock )
        {
            sm_local[key] = false;
            foreach( Thread t; sm_tbeg )
            {
                t.m_local[key] = null;
            }
        }
    }


    /**
     * Gets the data associated with the supplied key value.  It is assumed
     * that any key passed to this function is valid.
     *
     * Params:
     *  key = The location which holds the desired data.
     *
     * Returns:
     *  The data associated with the supplied key.
     */
    static void* getLocal( uint key )
    {
        return getThis().m_local[key];
    }


    /**
     * Stores the supplied value in the specified location.  It is assumed
     * that any key passed to this function is valid.
     *
     * Params:
     *  key = The location to store the supplied data.
     *  val = The data to store.
     *
     * Returns:
     *  A copy of the data which has just been stored.
     */
    static void* setLocal( uint key, void* val )
    {
        return getThis().m_local[key] = val;
    }


private:
    //
    // Initializes a thread object which has no associated executable function.
    // This is used for the main thread initialized in thread_init().
    //
    this()
    {
        m_call = Call.NO;
        m_curr = &m_main;
    }


    //
    // Thread entry point.  Invokes the function or delegate passed on
    // construction (if any).
    //
    final void run()
    {
        switch( m_call )
        {
        case Call.FN:
            m_fn();
            break;
        case Call.DG:
            m_dg();
            break;
        default:
            break;
        }
    }


private:
    //
    // The type of routine passed on thread construction.
    //
    enum Call
    {
        NO,
        FN,
        DG
    }


    //
    // Standard types
    //
    version( Win32 )
    {
        alias uint TLSKey;
        alias uint ThreadAddr;
    }
    else version( Posix )
    {
        alias pthread_key_t TLSKey;
        alias pthread_t     ThreadAddr;
    }


    //
    // Local storage
    //
    static bool[LOCAL_MAX]  sm_local;
    static TLSKey           sm_this;

    void*[LOCAL_MAX]        m_local;


    //
    // Standard thread data
    //
    version( Win32 )
    {
        HANDLE          m_hndl;
    }
    ThreadAddr          m_addr;
    Call                m_call;
    char[]              m_name;
    union
    {
        void function() m_fn;
        void delegate() m_dg;
    }
    version( Posix )
    {
        bool            m_isRunning;
    }
    Object              m_unhandled;


private:
    ////////////////////////////////////////////////////////////////////////////
    // Storage of Active Thread
    ////////////////////////////////////////////////////////////////////////////


    //
    // Sets a thread-local reference to the current thread object.
    //
    static void setThis( Thread t )
    {
        version( Win32 )
        {
            TlsSetValue( sm_this, cast(void*) t );
        }
        else version( Posix )
        {
            pthread_setspecific( sm_this, cast(void*) t );
        }
    }


private:
    ////////////////////////////////////////////////////////////////////////////
    // Thread Context and GC Scanning Support
    ////////////////////////////////////////////////////////////////////////////


    final void pushContext( Context* c )
    in
    {
        assert( !c.within );
    }
    body
    {
        c.within = m_curr;
        m_curr = c;
    }


    final void popContext()
    in
    {
        assert( m_curr && m_curr.within );
    }
    body
    {
        Context* c = m_curr;
        m_curr = c.within;
        c.within = null;
    }


    final Context* topContext()
    in
    {
        assert( m_curr );
    }
    body
    {
        return m_curr;
    }


    static struct Context
    {
        void*           bstack,
                        tstack;
        Context*        within;
        Context*        next,
                        prev;
    }


    Context             m_main;
    Context*            m_curr;
    bool                m_lock;

    version( Win32 )
    {
        uint[8]         m_reg; // edi,esi,ebp,esp,ebx,edx,ecx,eax
    }


private:
    ////////////////////////////////////////////////////////////////////////////
    // GC Scanning Support
    ////////////////////////////////////////////////////////////////////////////


    // NOTE: The GC scanning process works like so:
    //
    //          1. Suspend all threads.
    //          2. Scan the stacks of all suspended threads for roots.
    //          3. Resume all threads.
    //
    //       Step 1 and 3 require a list of all threads in the system, while
    //       step 2 requires a list of all thread stacks (each represented by
    //       a Context struct).  Traditionally, there was one stack per thread
    //       and the Context structs were not necessary.  However, Fibers have
    //       changed things so that each thread has its own 'main' stack plus
    //       an arbitrary number of nested stacks (normally referenced via
    //       m_curr).  Also, there may be 'free-floating' stacks in the system,
    //       which are Fibers that are not currently executing on any specific
    //       thread but are still being processed and still contain valid
    //       roots.
    //
    //       To support all of this, the Context struct has been created to
    //       represent a stack range, and a global list of Context structs has
    //       been added to enable scanning of these stack ranges.  The lifetime
    //       (and presence in the Context list) of a thread's 'main' stack will
    //       be equivalent to the thread's lifetime.  So the Ccontext will be
    //       added to the list on thread entry, and removed from the list on
    //       thread exit (which is essentially the same as the presence of a
    //       Thread object in its own global list).  The lifetime of a Fiber's
    //       context, however, will be tied to the lifetime of the Fiber object
    //       itself, and Fibers are expected to add/remove their Context struct
    //       on construction/deletion.


    //
    // All use of the global lists should synchronize on this lock.
    //
    static Object slock()
    {
        return Thread.classinfo;
    }


    static Context*     sm_cbeg;
    static size_t       sm_clen;

    static Thread       sm_tbeg;
    static size_t       sm_tlen;

    //
    // Used for ordering threads in the global thread list.
    //
    Thread              prev;
    Thread              next;


    ////////////////////////////////////////////////////////////////////////////
    // Global Context List Operations
    ////////////////////////////////////////////////////////////////////////////


    //
    // Add a context to the global context list.
    //
    static void add( Context* c )
    in
    {
        assert( c );
        assert( !c.next && !c.prev );
    }
    body
    {
        synchronized( slock )
        {
            if( sm_cbeg )
            {
                c.next = sm_cbeg;
                sm_cbeg.prev = c;
            }
            sm_cbeg = c;
            ++sm_clen;
        }
    }


    //
    // Remove a context from the global context list.
    //
    static void remove( Context* c )
    in
    {
        assert( c );
        assert( c.next || c.prev );
    }
    body
    {
        synchronized( slock )
        {
            if( c.prev )
                c.prev.next = c.next;
            if( c.next )
                c.next.prev = c.prev;
            if( sm_cbeg == c )
                sm_cbeg = c.next;
            --sm_clen;
        }
        // NOTE: Don't null out c.next or c.prev because opApply currently
        //       follows c.next after removing a node.  This could be easily
        //       addressed by simply returning the next node from this function,
        //       however, a context should never be re-added to the list anyway
        //       and having next and prev be non-null is a good way to
        //       ensure that.
    }


    ////////////////////////////////////////////////////////////////////////////
    // Global Thread List Operations
    ////////////////////////////////////////////////////////////////////////////


    //
    // Add a thread to the global thread list.
    //
    static void add( Thread t )
    in
    {
        assert( t );
        assert( !t.next && !t.prev );
        assert( t.isRunning );
    }
    body
    {
        synchronized( slock )
        {
            if( sm_tbeg )
            {
                t.next = sm_tbeg;
                sm_tbeg.prev = t;
            }
            sm_tbeg = t;
            ++sm_tlen;
        }
    }


    //
    // Remove a thread from the global thread list.
    //
    static void remove( Thread t )
    in
    {
        assert( t );
        assert( t.next || t.prev );
        version( Win32 )
        {
            // NOTE: This doesn't work for Posix as m_isRunning must be set to
            //       false after the thread is removed during normal execution.
            assert( !t.isRunning );
        }
    }
    body
    {
        synchronized( slock )
        {
            // NOTE: When a thread is removed from the global thread list its
            //       main context is invalid and should be removed as well.
            //       It is possible that t.m_curr could reference more
            //       than just the main context if the thread exited abnormally
            //       (if it was terminated), but we must assume that the user
            //       retains a reference to them and that they may be re-used
            //       elsewhere.  Therefore, it is the responsibility of any
            //       object that creates contexts to clean them up properly
            //       when it is done with them.
            remove( &t.m_main );

            if( t.prev )
                t.prev.next = t.next;
            if( t.next )
                t.next.prev = t.prev;
            if( sm_tbeg == t )
                sm_tbeg = t.next;
            --sm_tlen;
        }
        // NOTE: Don't null out t.next or t.prev because opApply currently
        //       follows t.next after removing a node.  This could be easily
        //       addressed by simply returning the next node from this function,
        //       however, a thread should never be re-added to the list anyway
        //       and having next and prev be non-null is a good way to
        //       ensure that.
    }
}


////////////////////////////////////////////////////////////////////////////////
// GC Support Routines
////////////////////////////////////////////////////////////////////////////////


/**
 * Initializes the thread module.  This function must be called by the
 * garbage collector on startup and before any other thread routines
 * are called.
 */
extern (C) void thread_init()
{
    // NOTE: If thread_init itself performs any allocations then the thread
    //       routines reserved for garbage collector use may be called while
    //       thread_init is being processed.  However, since no memory should
    //       exist to be scanned at this point, it is sufficient for these
    //       functions to detect the condition and return immediately.

    version( Win32 )
    {
        Thread.sm_this = TlsAlloc();
        assert( Thread.sm_this != TLS_OUT_OF_INDEXES );

        Thread          mainThread  = new Thread();
        Thread.Context* mainContext = &mainThread.m_main;
        assert( mainContext == mainThread.m_curr );

        mainThread.m_addr    = GetCurrentThreadId();
        mainThread.m_hndl    = GetCurrentThreadHandle();
        mainContext.bstack = getStackBottom();
        mainContext.tstack = mainContext.bstack;

        Thread.setThis( mainThread );
    }
    else version( Posix )
    {
        int         status;
        sigaction_t sigusr1 = void;
        sigaction_t sigusr2 = void;

        // This is a quick way to zero-initialize the structs without using
        // memset or creating a link dependency on their static initializer.
        (cast(byte*) &sigusr1)[0 .. sigaction_t.sizeof] = 0;
        (cast(byte*) &sigusr2)[0 .. sigaction_t.sizeof] = 0;

        // NOTE: SA_RESTART indicates that system calls should restart if they
        //       are interrupted by a signal, but this is not available on all
        //       Posix systems, even those that support multithreading.
        static if( is( typeof( SA_RESTART ) ) )
            sigusr1.sa_flags = SA_RESTART;
        else
            sigusr1.sa_flags   = 0;
        sigusr1.sa_handler = &thread_suspendHandler;
        // NOTE: We want to ignore all signals while in this handler, so fill
        //       sa_mask to indicate this.
        status = sigfillset( &sigusr1.sa_mask );
        assert( status == 0 );

        // NOTE: Since SIGUSR2 should only be issued for threads within the
        //       suspend handler, we don't want this signal to trigger a
        //       restart.
        sigusr2.sa_flags   = 0;
        sigusr2.sa_handler = &thread_resumeHandler;
        // NOTE: We want to ignore all signals while in this handler, so fill
        //       sa_mask to indicate this.
        status = sigfillset( &sigusr2.sa_mask );
        assert( status == 0 );

        status = sigaction( SIGUSR1, &sigusr1, null );
        assert( status == 0 );

        status = sigaction( SIGUSR2, &sigusr2, null );
        assert( status == 0 );

        status = sem_init( &suspendCount, 0, 0 );
        assert( status == 0 );

        status = pthread_key_create( &Thread.sm_this, null );
        assert( status == 0 );

        Thread          mainThread  = new Thread();
        Thread.Context* mainContext = mainThread.m_curr;
        assert( mainContext == &mainThread.m_main );

        mainThread.m_addr    = pthread_self();
        mainContext.bstack = getStackBottom();
        mainContext.tstack = mainContext.bstack;

        mainThread.m_isRunning = true;

        Thread.setThis( mainThread );
    }

    Thread.add( mainThread );
    Thread.add( mainContext );
}


/**
 * Performs intermediate shutdown of the thread module.
 */
static ~this()
{
    // NOTE: The functionality related to garbage collection must be minimally
    //       operable after this dtor completes.  Therefore, only minimal
    //       cleanup may occur.

    for( Thread t = Thread.sm_tbeg; t; t = t.next )
    {
        if( !t.isRunning )
            Thread.remove( t );
    }
}


// Used for needLock below
private bool multiThreadedFlag = false;


/**
 * This function is used to determine whether the the process is
 * multi-threaded.  Optimizations may only be performed on this
 * value if the programmer can guarantee that no path from the
 * enclosed code will start a thread.
 *
 * Returns:
 *  True if Thread.start() has been called in this process.
 */
extern (C) bool thread_needLock()
{
    return multiThreadedFlag;
}


// Used for suspendAll/resumeAll below
private uint suspendDepth = 0;


/**
 * Suspend all threads but the calling thread for "stop the world" garbage
 * collection runs.  This function may be called multiple times, and must
 * be followed by a matching number of calls to thread_resumeAll before
 * processing is resumed.
 *
 * Throws:
 *  ThreadException if the suspend operation fails for a running thread.
 */
extern (C) void thread_suspendAll()
{
    /**
     * Suspend the specified thread and load stack and register information for
     * use by thread_scanAll.  If the supplied thread is the calling thread,
     * stack and register information will be loaded but the thread will not
     * be suspended.  If the suspend operation fails and the thread is not
     * running then it will be removed from the global thread list, otherwise
     * an exception will be thrown.
     *
     * Params:
     *  t = The thread to suspend.
     *
     * Throws:
     *  ThreadException if the suspend operation fails for a running thread.
     */
    void suspend( Thread t )
    {
        version( Win32 )
        {
            if( t.m_addr != GetCurrentThreadId() && SuspendThread( t.m_hndl ) == 0xFFFFFFFF )
            {
                if( !t.isRunning )
                {
                    Thread.remove( t );
                    return;
                }
                throw new ThreadException( "Unable to suspend thread" );
            }

            CONTEXT context = void;
            context.ContextFlags = CONTEXT_INTEGER | CONTEXT_CONTROL;

            if( !GetThreadContext( t.m_hndl, &context ) )
                throw new ThreadException( "Unable to load thread context" );
            if( !t.m_lock )
                t.m_curr.tstack = cast(void*) context.Esp;
            // edi,esi,ebp,esp,ebx,edx,ecx,eax
            t.m_reg[0] = context.Edi;
            t.m_reg[1] = context.Esi;
            t.m_reg[2] = context.Ebp;
            t.m_reg[3] = context.Esp;
            t.m_reg[4] = context.Ebx;
            t.m_reg[5] = context.Edx;
            t.m_reg[6] = context.Ecx;
            t.m_reg[7] = context.Eax;
        }
        else version( Posix )
        {
            if( t.m_addr != pthread_self() )
            {
                if( pthread_kill( t.m_addr, SIGUSR1 ) != 0 )
                {
                    if( !t.isRunning )
                    {
                        Thread.remove( t );
                        return;
                    }
                    throw new ThreadException( "Unable to suspend thread" );
                }
                // NOTE: It's really not ideal to wait for each thread to signal
                //       individually -- rather, it would be better to suspend
                //       them all and wait once at the end.  However, semaphores
                //       don't really work this way, and the obvious alternative
                //       (looping on an atomic suspend count) requires either
                //       the atomic module (which only works on x86) or other
                //       specialized functionality.  It would also be possible
                //       to simply loop on sem_wait at the end, but I'm not
                //       convinced that this would be much faster than the
                //       current approach.
                sem_wait( &suspendCount );
            }
            else if( !t.m_lock )
            {
                t.m_curr.tstack = getStackTop();
            }
        }
    }


    // NOTE: We've got an odd chicken & egg problem here, because while the GC
    //       is required to call thread_init before calling any other thread
    //       routines, thread_init may allocate memory which could in turn
    //       trigger a collection.  Thus, thread_suspendAll, thread_scanAll,
    //       and thread_resumeAll must be callable before thread_init completes,
    //       with the assumption that no other GC memory has yet been allocated
    //       by the system, and thus there is no risk of losing data if the
    //       global thread list is empty.  The check of Thread.sm_tbeg
    //       below is done to ensure thread_init has completed, and therefore
    //       that calling Thread.getThis will not result in an error.  For the
    //       short time when Thread.sm_tbeg is null, there is no reason
    //       not to simply call the multithreaded code below, with the
    //       expectation that the foreach loop will never be entered.
    if( !multiThreadedFlag && Thread.sm_tbeg )
    {
        if( ++suspendDepth == 1 )
            suspend( Thread.getThis() );
        return;
    }
    synchronized( Thread.slock )
    {
        if( ++suspendDepth > 1 )
            return;

        // NOTE: I'd really prefer not to check isRunning within this loop but
        //       not doing so could be problematic if threads are termianted
        //       abnormally and a new thread is created with the same thread
        //       address before the next GC run.  This situation might cause
        //       the same thread to be suspended twice, which would likely
        //       cause the second suspend to fail, the garbage collection to
        //       abort, and Bad Things to occur.
        for( Thread t = Thread.sm_tbeg; t; t = t.next )
        {
            if( t.isRunning )
                suspend( t );
            else
                Thread.remove( t );
        }

        version( Posix )
        {
            // wait on semaphore -- see note in suspend for
            // why this is currently not implemented
        }
    }
}


/**
 * Resume all threads but the calling thread for "stop the world" garbage
 * collection runs.  This function must be called once for each preceding
 * call to thread_suspendAll before the threads are actually resumed.
 *
 * In:
 *  This routine must be preceded by a call to thread_suspendAll.
 *
 * Throws:
 *  ThreadException if the resume operation fails for a running thread.
 */
extern (C) void thread_resumeAll()
in
{
    assert( suspendDepth > 0 );
}
body
{
    /**
     * Resume the specified thread and unload stack and register information.
     * If the supplied thread is the calling thread, stack and register
     * information will be unloaded but the thread will not be resumed.  If
     * the resume operation fails and the thread is not running then it will
     * be removed from the global thread list, otherwise an exception will be
     * thrown.
     *
     * Params:
     *  t = The thread to resume.
     *
     * Throws:
     *  ThreadException if the resume fails for a running thread.
     */
    void resume( Thread t )
    {
        version( Win32 )
        {
            if( t.m_addr != GetCurrentThreadId() && ResumeThread( t.m_hndl ) == 0xFFFFFFFF )
            {
                if( !t.isRunning )
                {
                    Thread.remove( t );
                    return;
                }
                throw new ThreadException( "Unable to resume thread" );
            }

            if( !t.m_lock )
                t.m_curr.tstack = t.m_curr.bstack;
            t.m_reg[0 .. $] = 0;
        }
        else version( Posix )
        {
            if( t.m_addr != pthread_self() )
            {
                if( pthread_kill( t.m_addr, SIGUSR2 ) != 0 )
                {
                    if( !t.isRunning )
                    {
                        Thread.remove( t );
                        return;
                    }
                    throw new ThreadException( "Unable to resume thread" );
                }
            }
            else if( !t.m_lock )
            {
                t.m_curr.tstack = t.m_curr.bstack;
            }
        }
    }


    // NOTE: See thread_suspendAll for the logic behind this.
    if( !multiThreadedFlag && Thread.sm_tbeg )
    {
        if( --suspendDepth == 0 )
            resume( Thread.getThis() );
        return;
    }
    synchronized( Thread.slock )
    {
        if( --suspendDepth > 0 )
            return;

        for( Thread t = Thread.sm_tbeg; t; t = t.next )
        {
            resume( t );
        }
    }
}


private alias void delegate( void*, void* ) scanAllThreadsFn;


/**
 * The main entry point for garbage collection.  The supplied delegate
 * will be passed ranges representing both stack and register values.
 *
 * Params:
 *  scan        = The scanner function.  It should scan from p1 through p2 - 1.
 *  curStackTop = An optional pointer to the top of the calling thread's stack.
 *
 * In:
 *  This routine must be preceded by a call to thread_suspendAll.
 */
extern (C) void thread_scanAll( scanAllThreadsFn scan, void* curStackTop = null )
in
{
    assert( suspendDepth > 0 );
}
body
{
    Thread  thisThread  = null;
    void*   oldStackTop = null;

    if( curStackTop && Thread.sm_tbeg )
    {
        thisThread  = Thread.getThis();
        if( !thisThread.m_lock )
        {
            oldStackTop = thisThread.m_curr.tstack;
            thisThread.m_curr.tstack = curStackTop;
        }
    }

    scope( exit )
    {
        if( curStackTop && Thread.sm_tbeg )
        {
            if( !thisThread.m_lock )
            {
                thisThread.m_curr.tstack = oldStackTop;
            }
        }
    }

    // NOTE: Synchronizing on Thread.slock is not needed because this
    //       function may only be called after all other threads have
    //       been suspended from within the same lock.
    for( Thread.Context* c = Thread.sm_cbeg; c; c = c.next )
    {
        version( StackGrowsDown )
        {
            // NOTE: We can't index past the bottom of the stack
            //       so don't do the "+1" for StackGrowsDown.
            if( c.tstack && c.tstack < c.bstack )
                scan( c.tstack, c.bstack );
        }
        else
        {
            if( c.bstack && c.bstack < c.tstack )
                scan( c.bstack, c.tstack + 1 );
        }
    }
    version( Win32 )
    {
        for( Thread t = Thread.sm_tbeg; t; t = t.next )
        {
            scan( &t.m_reg[0], &t.m_reg[0] + t.m_reg.length );
        }
    }
}


////////////////////////////////////////////////////////////////////////////////
// Thread Local
////////////////////////////////////////////////////////////////////////////////


/**
 * This class encapsulates the operations required to initialize, access, and
 * destroy thread local data.
 */
class ThreadLocal( T )
{
    ////////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////////


    /**
     * Initializes thread local storage for the indicated value which will be
     * initialized to def for all threads.
     *
     * Params:
     *  def = The default value to return if no value has been explicitly set.
     */
    this( T def = T.init )
    {
        m_def = def;
        m_key = Thread.createLocal();
    }


    ~this()
    {
        Thread.deleteLocal( m_key );
    }


    ////////////////////////////////////////////////////////////////////////////
    // Accessors
    ////////////////////////////////////////////////////////////////////////////


    /**
     * Gets the value last set by the calling thread, or def if no such value
     * has been set.
     *
     * Returns:
     *  The stored value or def if no value is stored.
     */
    T val()
    {
        Wrap* wrap = cast(Wrap*) Thread.getLocal( m_key );

        return wrap ? wrap.val : m_def;
    }


    /**
     * Copies newval to a location specific to the calling thread, and returns
     * newval.
     *
     * Params:
     *  newval = The value to set.
     *
     * Returns:
     *  The value passed to this function.
     */
    T val( T newval )
    {
        Wrap* wrap = cast(Wrap*) Thread.getLocal( m_key );

        if( wrap is null )
        {
            wrap = new Wrap;
            Thread.setLocal( m_key, wrap );
        }
        wrap.val = newval;
        return newval;
    }


private:
    //
    // A wrapper for the stored data.  This is needed for determining whether
    // set has ever been called for this thread (and therefore whether the
    // default value should be returned) and also to flatten the differences
    // between data that is smaller and larger than (void*).sizeof.  The
    // obvious tradeoff here is an extra per-thread allocation for each
    // ThreadLocal value as compared to calling the Thread routines directly.
    //
    struct Wrap
    {
        T   val;
    }


    T       m_def;
    uint    m_key;
}


////////////////////////////////////////////////////////////////////////////////
// Thread Group
////////////////////////////////////////////////////////////////////////////////


/**
 * This class is intended to simplify certain common programming techniques.
 */
class ThreadGroup
{
    /**
     * Creates and starts a new Thread object that executes fn and adds it to
     * the list of tracked threads.
     *
     * Params:
     *  fn = The thread function.
     *
     * Returns:
     *  A reference to the newly created thread.
     */
    final Thread create( void function() fn )
    {
        Thread t = new Thread( fn );

        t.start();
        synchronized
        {
            m_all[t] = t;
        }
        return t;
    }


    /**
     * Creates and starts a new Thread object that executes dg and adds it to
     * the list of tracked threads.
     *
     * Params:
     *  dg = The thread function.
     *
     * Returns:
     *  A reference to the newly created thread.
     */
    final Thread create( void delegate() dg )
    {
        Thread t = new Thread( dg );

        t.start();
        synchronized
        {
            m_all[t] = t;
        }
        return t;
    }


    /**
     * Add t to the list of tracked threads if it is not already being tracked.
     *
     * Params:
     *  t = The thread to add.
     *
     * In:
     *  t must not be null.
     */
    final void add( Thread t )
    in
    {
        assert( t );
    }
    body
    {
        synchronized
        {
            m_all[t] = t;
        }
    }


    /**
     * Removes t from the list of tracked threads.  No operation will be
     * performed if t is not currently being tracked by this object.
     *
     * Params:
     *  t = The thread to remove.
     *
     * In:
     *  t must not be null.
     */
    final void remove( Thread t )
    in
    {
        assert( t );
    }
    body
    {
        synchronized
        {
            m_all.remove( t );
        }
    }


    /**
     * Operates on all threads currently tracked by this object.
     */
    final int opApply( int delegate( inout Thread ) dg )
    {
        synchronized
        {
            int ret = 0;

            // NOTE: This loop relies on the knowledge that m_all uses the
            //       Thread object for both the key and the mapped value.
            foreach( Thread t; m_all.keys )
            {
                ret = dg( t ); // ret = dg( t );
                if( ret )
                    break;
            }
            return ret;
        }
    }


    /**
     * Iteratively joins all tracked threads.  This function will block add,
     * remove, and opApply until it completes.
     *
     * Params:
     *  rethrow = Rethrow any unhandled exception which may have caused the
     *            current thread to terminate.
     *
     * Throws:
     *  Any exception not handled by the joined threads.
     */
    final void joinAll( bool rethrow = true )
    {
        synchronized
        {
            // NOTE: This loop relies on the knowledge that m_all uses the
            //       Thread object for both the key and the mapped value.
            foreach( Thread t; m_all.keys )
            {
                t.join( rethrow );
            }
        }
    }


private:
    Thread[Thread]  m_all;
}


////////////////////////////////////////////////////////////////////////////////
// Fiber Platform Detection and Memory Allocation
////////////////////////////////////////////////////////////////////////////////


private
{
    version( D_InlineAsm_X86 )
    {
        version( X86_64 )
        {

        }
        else
        {
            version( Win32 )
                version = AsmX86_Win32;
            else version( Posix )
                version = AsmX86_Posix;
        }
    }
    else version( PPC )
    {
        version( Posix )
            version = AsmPPC_Posix;
    }


    version( Posix )
    {
        import tango.stdc.posix.unistd;   // for sysconf
        import tango.stdc.posix.sys.mman; // for mmap
        import tango.stdc.posix.stdlib;   // for malloc, valloc, free

        version( AsmX86_Win32 ) {} else
        version( AsmX86_Posix ) {} else
        version( AsmPPC_Posix ) {} else
        {
            // NOTE: The ucontext implementation requires architecture specific
            //       data definitions to operate so testing for it must be done
            //       by checking for the existence of ucontext_t rather than by
            //       a version identifier.  This is considered an obsolescent
            //       feature, according to the POSIX spec, so a custom solution
            //       is still preferred.
            import tango.stdc.posix.ucontext;
        }
    }

    const size_t PAGESIZE;
}


static this()
{
    static if( is( typeof( GetSystemInfo ) ) )
    {
        SYSTEM_INFO info;
        GetSystemInfo( &info );

        PAGESIZE = info.dwPageSize;
        assert( PAGESIZE < int.max );
    }
    else static if( is( typeof( sysconf ) ) &&
                    is( typeof( _SC_PAGESIZE ) ) )
    {
        PAGESIZE = sysconf( _SC_PAGESIZE );
        assert( PAGESIZE < int.max );
    }
    else
    {
        version( PPC )
            PAGESIZE = 8192;
        else
            PAGESIZE = 4096;
    }
}


////////////////////////////////////////////////////////////////////////////////
// Fiber Entry Point and Context Switch
////////////////////////////////////////////////////////////////////////////////


private
{
    extern (C) void fiber_entryPoint()
    {
        Fiber   obj = Fiber.getThis();
        assert( obj );

        obj.m_state = Fiber.State.EXEC;

        try
        {
            obj.run();
        }
        catch( Object o )
        {
            obj.m_unhandled = o;
        }

        obj.m_state = Fiber.State.TERM;
        obj.switchOut();
    }


  // NOTE: If AsmPPC_Posix is defined then the context switch routine will
  //       be defined externally until GDC supports inline PPC ASM.
  version( AsmPPC_Posix )
    extern (C) void fiber_switchContext( void** oldp, void* newp );
  else
    extern (C) void fiber_switchContext( void** oldp, void* newp )
    {
        // NOTE: The data pushed and popped in this routine must match the
        //       default stack created by Fiber.initStack or the initial
        //       switch into a new context will fail.

        version( AsmX86_Win32 )
        {
            asm
            {
                naked;

                // save current stack state
                push EBP;
                mov  EBP, ESP;
                push EAX;
                push dword ptr FS:[0];
                push dword ptr FS:[4];
                push dword ptr FS:[8];
                push EBX;
                push ESI;
                push EDI;

                // store oldp again with more accurate address
                mov EAX, dword ptr 8[EBP];
                mov [EAX], ESP;
                // load newp to begin context switch
                mov ESP, dword ptr 12[EBP];

                // load saved state from new stack
                pop EDI;
                pop ESI;
                pop EBX;
                pop dword ptr FS:[8];
                pop dword ptr FS:[4];
                pop dword ptr FS:[0];
                pop EAX;
                pop EBP;

                // 'return' to complete switch
                ret;
            }
        }
        else version( AsmX86_Posix )
        {
            asm
            {
                naked;

                // save current stack state
                push EBP;
                mov  EBP, ESP;
                push EAX;
                push EBX;
                push ESI;
                push EDI;

                // store oldp again with more accurate address
                mov EAX, dword ptr 8[EBP];
                mov [EAX], ESP;
                // load newp to begin context switch
                mov ESP, dword ptr 12[EBP];

                // load saved state from new stack
                pop EDI;
                pop ESI;
                pop EBX;
                pop EAX;
                pop EBP;

                // 'return' to complete switch
                ret;
            }
        }
        else static if( is( typeof( ucontext_t ) ) )
        {
            swapcontext( **(cast(ucontext_t***) oldp),
                          *(cast(ucontext_t**)  newp) );
        }
    }
}


////////////////////////////////////////////////////////////////////////////////
// Fiber
////////////////////////////////////////////////////////////////////////////////


/**
 * This class provides a cooperative concurrency mechanism integrated with the
 * threading and garbage collection functionality.  Calling a fiber may be
 * considered a blocking operation that returns when the fiber yields (via
 * Fiber.yield()).  Execution occurs within the context of the calling thread
 * so synchronization is not necessary to guarantee memory visibility so long
 * as the same thread calls the fiber each time.  Please note that there is no
 * requirement that a fiber be bound to one specific thread.  Rather, fibers
 * may be freely passed between threads so long as they are not currently
 * executing.  Like threads, a new fiber thread may be created using either
 * derivation or composition, as in the following example.
 *
 * Example:
 * ----------------------------------------------------------------------
 *
 * class DerivedFiber : Fiber
 * {
 *     this()
 *     {
 *         super( &run );
 *     }
 *
 * private :
 *     void run()
 *     {
 *         printf( "Derived fiber running.\n" );
 *     }
 * }
 *
 * void fiberFunc()
 * {
 *     printf( "Composed fiber running.\n" );
 *     Fiber.yield();
 *     printf( "Composed fiber running.\n" );
 * }
 *
 * // create instances of each type
 * Fiber derived = new DerivedFiber();
 * Fiber composed = new Fiber( &fiberFunc );
 *
 * // call both fibers once
 * derived.call();
 * composed.call();
 * printf( "Execution returned to calling context.\n" );
 * composed.call();
 *
 * // since each fiber has run to completion, each should have state TERM
 * assert( derived.state == Fiber.State.TERM );
 * assert( composed.state == Fiber.State.TERM );
 *
 * ----------------------------------------------------------------------
 *
 * Authors: Based on a design by Mikola Lysenko.
 */
class Fiber
{
    ////////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////////


    /**
     * Initializes a fiber object which is associated with a static
     * D function.
     *
     * Params:
     *  fn = The thread function.
     *  sz = The stack size for this fiber.
     *
     * In:
     *  fn must not be null.
     */
    this( void function() fn, size_t sz = PAGESIZE )
    in
    {
        assert( fn );
    }
    body
    {
        m_fn    = fn;
        m_call  = Call.FN;
        m_state = State.HOLD;
        allocStack( sz );
        initStack();
    }


    /**
     * Initializes a fiber object which is associated with a dynamic
     * D function.
     *
     * Params:
     *  dg = The thread function.
     *  sz = The stack size for this fiber.
     *
     * In:
     *  dg must not be null.
     */
    this( void delegate() dg, size_t sz = PAGESIZE )
    in
    {
        assert( dg );
    }
    body
    {
        m_dg    = dg;
        m_call  = Call.DG;
        m_state = State.HOLD;
        allocStack( sz );
        initStack();
    }


    /**
     * Cleans up any remaining resources used by this object.
     */
    ~this()
    {
        // NOTE: A live reference to this object will exist on its associated
        //       stack from the first time its call() method has been called
        //       until its execution completes with State.TERM.  Thus, the only
        //       times this dtor should be called are either if the fiber has
        //       terminated (and therefore has no active stack) or if the user
        //       explicitly deletes this object.  The latter case is an error
        //       but is not easily tested for, since State.HOLD may imply that
        //       the fiber was just created but has never been run.  There is
        //       not a compelling case to create a State.INIT just to offer a
        //       means of ensuring the user isn't violating this object's
        //       contract, so for now this requirement will be enforced by
        //       documentation only.
        freeStack();
    }


    ////////////////////////////////////////////////////////////////////////////
    // General Actions
    ////////////////////////////////////////////////////////////////////////////


    /**
     * Transfers execution to this fiber object.  The calling context will be
     * suspended until the fiber calls Fiber.yield() or until it terminates
     * via an unhandled exception.
     *
     * Params:
     *  rethrow = Rethrow any unhandled exception which may have caused this
     *            fiber to terminate.
     *
     * In:
     *  This fiber must be in state HOLD.
     *
     * Throws:
     *  Any exception not handled by the joined thread.
     */
    final void call( bool rethrow = true )
    in
    {
        assert( m_state == State.HOLD );
    }
    body
    {
        Fiber   cur = getThis();

        setThis( this );
        this.switchIn();
        setThis( cur );

        // NOTE: If the fiber has terminated then the stack pointers must be
        //       reset.  This ensures that the stack for this fiber is not
        //       scanned if the fiber has terminated.  This is necessary to
        //       prevent any references lingering on the stack from delaying
        //       the collection of otherwise dead objects.  The most notable
        //       being the current object, which is referenced at the top of
        //       fiber_entryPoint.
        if( m_state == State.TERM )
        {
            m_ctxt.tstack = m_ctxt.bstack;
        }
        if( m_unhandled )
        {
            Object obj  = m_unhandled;
            m_unhandled = null;
            if( rethrow )
            {
                throw obj;
            }
        }
    }


    /**
     * Resets this fiber so that it may be re-used.  This routine may only be
     * called for fibers that have terminated, as doing otherwise could result
     * in scope-dependent functionality that is not executed.  Stack-based
     * classes, for example, may not be cleaned up properly if a fiber is reset
     * before it has terminated.
     *
     * In:
     *  This fiber must be in state TERM.
     */
    final void reset()
    in
    {
        assert( m_state == State.TERM );
        assert( m_ctxt.tstack == m_ctxt.bstack );
    }
    body
    {
        m_state = State.HOLD;
        initStack();
        m_unhandled = null;
    }


    ////////////////////////////////////////////////////////////////////////////
    // General Properties
    ////////////////////////////////////////////////////////////////////////////


    /**
     * A fiber may occupy one of three states: HOLD, EXEC, and TERM.  The HOLD
     * state applies to any fiber that is suspended and ready to be called.
     * The EXEC state will be set for any fiber that is currently executing.
     * And the TERM state is set when a fiber terminates.  Once a fiber
     * terminates, it must be reset before it may be called again.
     */
    enum State
    {
        HOLD,   ///
        EXEC,   ///
        TERM    ///
    }


    /**
     * Gets the current state of this fiber.
     *
     * Returns:
     *  The state of this fiber as an enumerated value.
     */
    final State state()
    {
        return m_state;
    }


    ////////////////////////////////////////////////////////////////////////////
    // Actions on Calling Fiber
    ////////////////////////////////////////////////////////////////////////////


    /**
     * Forces a context switch to occur away from the calling fiber.
     */
    static void yield()
    {
        Fiber   cur = getThis();
        assert( cur, "Fiber.yield() called with no active fiber" );
        assert( cur.m_state == State.EXEC );

        cur.m_state = State.HOLD;
        cur.switchOut();
        cur.m_state = State.EXEC;
    }


    /**
     * Forces a context switch to occur away from the calling fiber and then
     * throws obj in the calling fiber.
     *
     * Params:
     *  obj = The object to throw.
     *
     * In:
     *  obj must not be null.
     */
    static void yieldAndThrow( Object obj )
    in
    {
        assert( obj );
    }
    body
    {
        Fiber   cur = getThis();
        assert( cur, "Fiber.yield() called with no active fiber" );
        assert( cur.m_state == State.EXEC );

        cur.m_unhandled = obj;
        cur.m_state = State.HOLD;
        cur.switchOut();
        cur.m_state = State.EXEC;
    }


    ////////////////////////////////////////////////////////////////////////////
    // Fiber Accessors
    ////////////////////////////////////////////////////////////////////////////


    /**
     * Provides a reference to the calling fiber or null if no fiber is
     * currently active.
     *
     * Returns:
     *  The fiber object representing the calling fiber or null if no fiber
     *  is currently active.  The result of deleting this object is undefined.
     */
    static Fiber getThis()
    {
        version( Win32 )
        {
            return cast(Fiber) TlsGetValue( sm_this );
        }
        else version( Posix )
        {
            return cast(Fiber) pthread_getspecific( sm_this );
        }
    }


    ////////////////////////////////////////////////////////////////////////////
    // Static Initialization
    ////////////////////////////////////////////////////////////////////////////


    static this()
    {
        version( Win32 )
        {
            sm_this = TlsAlloc();
            assert( sm_this != TLS_OUT_OF_INDEXES );
        }
        else version( Posix )
        {
            int status;

            status = pthread_key_create( &sm_this, null );
            assert( status == 0 );
        }
    }


private:
    //
    // Initializes a fiber object which has no associated executable function.
    //
    this()
    {
        m_call = Call.NO;
    }


    //
    // Fiber entry point.  Invokes the function or delegate passed on
    // construction (if any).
    //
    final void run()
    {
        switch( m_call )
        {
        case Call.FN:
            m_fn();
            break;
        case Call.DG:
            m_dg();
            break;
        default:
            break;
        }
    }


private:
    //
    // The type of routine passed on fiber construction.
    //
    enum Call
    {
        NO,
        FN,
        DG
    }


    //
    // Standard fiber data
    //
    Call                m_call;
    union
    {
        void function() m_fn;
        void delegate() m_dg;
    }
    bool                m_isRunning;
    Object              m_unhandled;
    State               m_state;


private:
    ////////////////////////////////////////////////////////////////////////////
    // Stack Management
    ////////////////////////////////////////////////////////////////////////////


    //
    // Allocate a new stack for this fiber.
    //
    final void allocStack( size_t sz )
    in
    {
        assert( !m_pmem && !m_ctxt );
    }
    body
    {
        // adjust alloc size to a multiple of PAGESIZE
        sz += PAGESIZE - 1;
        sz -= sz % PAGESIZE;

        // NOTE: This instance of Thread.Context is dynamic so Fiber objects
        //       can be collected by the GC so long as no user level references
        //       to the object exist.  If m_ctxt were not dynamic then its
        //       presence in the global context list would be enough to keep
        //       this object alive indefinitely.  An alternative to allocating
        //       room for this struct explicitly would be to mash it into the
        //       base of the stack being allocated below.  However, doing so
        //       requires too much special logic to be worthwhile.
        m_ctxt = new Thread.Context;

        static if( is( typeof( VirtualAlloc ) ) )
        {
            // reserve memory for stack
            m_pmem = VirtualAlloc( null,
                                   sz + PAGESIZE,
                                   MEM_RESERVE,
                                   PAGE_NOACCESS );
            if( !m_pmem )
            {
                throw new FiberException( "Unable to reserve memory for stack" );
            }

            version( StackGrowsDown )
            {
                void* stack = m_pmem + PAGESIZE;
                void* guard = m_pmem;
                void* pbase = stack + sz;
            }
            else
            {
                void* stack = m_pmem;
                void* guard = m_pmem + sz;
                void* pbase = stack;
            }

            // allocate reserved stack segment
            stack = VirtualAlloc( stack,
                                  sz,
                                  MEM_COMMIT,
                                  PAGE_READWRITE );
            if( !stack )
            {
                throw new FiberException( "Unable to allocate memory for stack" );
            }

            // allocate reserved guard page
            guard = VirtualAlloc( guard,
                                  PAGESIZE,
                                  MEM_COMMIT,
                                  PAGE_READWRITE | PAGE_GUARD );
            if( !guard )
            {
                throw new FiberException( "Unable to create guard page for stack" );
            }

            m_ctxt.bstack = pbase;
            m_ctxt.tstack = pbase;
            m_size = sz;
        }
        else
        {   static if( is( typeof( mmap ) ) )
            {
                m_pmem = mmap( null,
                               sz,
                               PROT_READ | PROT_WRITE,
                               MAP_PRIVATE | MAP_ANON,
                               -1,
                               0 );
                if( m_pmem == MAP_FAILED )
                    m_pmem = null;
            }
            else static if( is( typeof( valloc ) ) )
            {
                m_pmem = valloc( sz );
            }
            else static if( is( typeof( malloc ) ) )
            {
                m_pmem = malloc( sz );
            }
            else
            {
                m_pmem = null;
            }

            if( !m_pmem )
            {
                throw new FiberException( "Unable to allocate memory for stack" );
            }

            version( StackGrowsDown )
            {
                m_ctxt.bstack = m_pmem + sz;
                m_ctxt.tstack = m_pmem + sz;
            }
            else
            {
                m_ctxt.bstack = m_pmem;
                m_ctxt.tstack = m_pmem;
            }
            m_size = sz;
        }

        Thread.add( m_ctxt );
    }


    //
    // Free this fiber's stack.
    //
    final void freeStack()
    in
    {
        assert( m_pmem && m_ctxt );
    }
    body
    {
        // NOTE: Since this routine is only ever expected to be called from
        //       the dtor, pointers to freed data are not set to null.

        // NOTE: m_ctxt is guaranteed to be alive because it is held in the
        //       global context list.
        Thread.remove( m_ctxt );

        static if( is( typeof( VirtualAlloc ) ) )
        {
            VirtualFree( m_pmem, 0, MEM_RELEASE );
        }
        else static if( is( typeof( mmap ) ) )
        {
            munmap( m_pmem, m_size );
        }
        else static if( is( typeof( valloc ) ) )
        {
            free( m_pmem );
        }
        else static if( is( typeof( malloc ) ) )
        {
            free( m_pmem );
        }
        delete m_ctxt;
    }


    //
    // Initialize the allocated stack.
    //
    final void initStack()
    in
    {
        assert( m_ctxt.tstack && m_ctxt.tstack == m_ctxt.bstack );
        assert( cast(size_t) m_ctxt.bstack % (void*).sizeof == 0 );
    }
    body
    {
        void* pstack = m_ctxt.tstack;
        scope( exit )  m_ctxt.tstack = pstack;

        void push( size_t val )
        {
            version( StackGrowsDown )
            {
                pstack -= size_t.sizeof;
                *(cast(size_t*) pstack) = val;
            }
            else
            {
                *(cast(size_t*) pstack) = val;
                pstack += size_t.sizeof;
            }
        }

        // NOTE: On OS X the stack must be 16-byte aligned according to the
        // IA-32 call spec.
        version( darwin )
        {
             pstack = cast(void*)(cast(uint)(pstack) - (cast(uint)(pstack) & 0x0F));
        }

        version( AsmX86_Win32 )
        {
            push( cast(size_t) &fiber_entryPoint );                 // EIP
            push( 0xFFFFFFFF );                                     // EBP
            push( 0x00000000 );                                     // EAX
            push( 0xFFFFFFFF );                                     // FS:[0]
            // BUG: Are the frame pointers the same for both versions?
            version( StackGrowsDown )
            {
                push( cast(size_t) m_ctxt.bstack );                 // FS:[4]
                push( cast(size_t) m_ctxt.bstack + m_size );        // FS:[8]
            }
            else
            {
                push( cast(size_t) m_ctxt.bstack );                 // FS:[4]
                push( cast(size_t) m_ctxt.bstack + m_size );        // FS:[8]
            }
            push( 0x00000000 );                                     // EBX
            push( 0x00000000 );                                     // ESI
            push( 0x00000000 );                                     // EDI
        }
        else version( AsmX86_Posix )
        {
            push( cast(size_t) &fiber_entryPoint );                 // EIP
            push( 0x00000000 );                                     // EBP
            push( 0x00000000 );                                     // EAX
            push( 0x00000000 );                                     // EBX
            push( 0x00000000 );                                     // ESI
            push( 0x00000000 );                                     // EDI
        }
        else version( AsmPPC_Posix )
        {
            version( StackGrowsDown )
            {
                pstack -= int.sizeof * 5;
            }
            else
            {
                pstack += int.sizeof * 5;
            }

            push( cast(size_t) &fiber_entryPoint );     // link register
            push( 0x00000000 );                         // control register
            push( 0x00000000 );                         // old stack pointer

            // GPR values
            version( StackGrowsDown )
            {
                pstack -= int.sizeof * 20;
            }
            else
            {
                pstack += int.sizeof * 20;
            }

            assert( cast(uint) pstack & 0x0f == 0 );
        }
        else static if( is( typeof( ucontext_t ) ) )
        {
            (cast(byte*) &m_utxt)[0 .. ucontext_t.sizeof] = 0;
            m_utxt.uc_stack.ss_sp   = m_ctxt.bstack;
            m_utxt.uc_stack.ss_size = m_size;
            makecontext( &m_utxt, &fiber_entryPoint, 0 );
            push( cast(size_t) &m_utxt );
        }
    }


    Thread.Context* m_ctxt;
    size_t          m_size;
    void*           m_pmem;

    static if( is( typeof( ucontext_t ) ) )
      ucontext_t    m_utxt = void;


private:
    ////////////////////////////////////////////////////////////////////////////
    // Storage of Active Fiber
    ////////////////////////////////////////////////////////////////////////////


    //
    // Sets a thread-local reference to the current fiber object.
    //
    static void setThis( Fiber f )
    {
        version( Win32 )
        {
            TlsSetValue( sm_this, cast(void*) f );
        }
        else version( Posix )
        {
            pthread_setspecific( sm_this, cast(void*) f );
        }
    }


    static Thread.TLSKey    sm_this;


private:
    ////////////////////////////////////////////////////////////////////////////
    // Context Switching
    ////////////////////////////////////////////////////////////////////////////


    //
    // Switches into the stack held by this fiber.
    //
    final void switchIn()
    {
        Thread  tobj = Thread.getThis();
        void**  oldp = &tobj.m_curr.tstack;
        void*   newp = m_ctxt.tstack;
        static if( is( typeof( ucontext_t ) ) )
          void* utxt = &m_utxt;

        // NOTE: The order of operations here is very important.  The current
        //       stack top must be stored before m_lock is set, and pushContext
        //       must not be called until after m_lock is set.  This process
        //       is intended to prevent a race condition with the suspend
        //       mechanism used for garbage collection.  If it is not followed,
        //       a badly timed collection could cause the GC to scan from the
        //       bottom of one stack to the top of another, or to miss scanning
        //       a stack that still contains valid data.  The old stack pointer
        //       oldp will be set again before the context switch to guarantee
        //       that it points to exactly the correct stack location so the
        //       successive pop operations will succeed.
        static if( is( typeof( ucontext_t ) ) )
          *oldp = &utxt;
        else
          *oldp = getStackTop();
        volatile tobj.m_lock = true;
        tobj.pushContext( m_ctxt );

        fiber_switchContext( oldp, newp );

        // NOTE: As above, these operations must be performed in a strict order
        //       to prevent Bad Things from happening.
        tobj.popContext();
        volatile tobj.m_lock = false;
        tobj.m_curr.tstack = tobj.m_curr.bstack;
    }


    //
    // Switches out of the current stack and into the enclosing stack.
    //
    final void switchOut()
    {
        Thread  tobj = Thread.getThis();
        void**  oldp = &m_ctxt.tstack;
        void*   newp = tobj.m_curr.within.tstack;
        static if( is( typeof( ucontext_t ) ) )
          void* utxt = &m_utxt;

        // NOTE: The order of operations here is very important.  The current
        //       stack top must be stored before m_lock is set, and pushContext
        //       must not be called until after m_lock is set.  This process
        //       is intended to prevent a race condition with the suspend
        //       mechanism used for garbage collection.  If it is not followed,
        //       a badly timed collection could cause the GC to scan from the
        //       bottom of one stack to the top of another, or to miss scanning
        //       a stack that still contains valid data.  The old stack pointer
        //       oldp will be set again before the context switch to guarantee
        //       that it points to exactly the correct stack location so the
        //       successive pop operations will succeed.
        static if( is( typeof( ucontext_t ) ) )
          *oldp = &utxt;
        else
          *oldp = getStackTop();
        volatile tobj.m_lock = true;

        fiber_switchContext( oldp, newp );

        // NOTE: As above, these operations must be performed in a strict order
        //       to prevent Bad Things from happening.
        volatile tobj.m_lock = false;
        tobj.m_curr.tstack = tobj.m_curr.bstack;
    }
}
