module tango.sys.consts.errno;
import tango.sys.consts.constSupport;

version(X86) {
    version=X86_CPU;
} else version(X86_64) {
    version=X86_CPU;
} else version ( PPC64 )
{
    version=PPC_CPU;
} else version ( PPC ) {
    version=PPC_CPU;
} else version(ARM){
} else version(SPARC){
} else {
    static assert(0,"unknown cpu family");
}

version(autoconf){
    public import tango.sys.consts.autoconf.errno;
} else version (Windows) {
    version (X86_CPU) {
        static if ((void*).sizeof==4)
            public import tango.sys.win32.consts.errno;
        else {
            pragma(msg,"constants not confirmed, please help out");
            public import tango.sys.win32.consts.errno;
        }
    } else {
        mixin undefinedConsts!("windows on non X86 CPU",__FILE__,__LINE__);
    }
} else version (darwin) {
    version (X86_CPU) {
        public import tango.sys.darwin.consts.errno;
    } else version (PPC_CPU) {
        public import tango.sys.darwin.consts.errno;
    } else {
        mixin undefinedConsts!("mac on non X86 or PPC CPU",__FILE__,__LINE__);
    }
} else version (linux) {
    version (X86_CPU) {
        public import tango.sys.linux.consts.errno;
    } else version (PPC_CPU) {
        public import tango.sys.linux.consts.errno;
    } else {
        mixin undefinedConsts!("linux on non X86 or PPC CPU",__FILE__,__LINE__);
    }
} else version (freebsd) {
    version (X86) {
        public import tango.sys.freebsd.consts.errno;
    } else {
        mixin undefinedConsts!("freebsd on non X86 ",__FILE__,__LINE__);
    }
} else version (solaris) {
    version (X86) {
        public import tango.sys.solaris.consts.errno;
    } else {
        mixin undefinedConsts!("solaris on non X86 ",__FILE__,__LINE__);
    }
}
