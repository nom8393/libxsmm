# export all variables to sub-make processes
export

# Use ROW_MAJOR matrix representation if set to 1, COL_MAJOR otherwise 
ROW_MAJOR ?= 1

# Separate M, N, and K lists allow generating M,N,K-combinations according to the loop nest M(N(K)))
# However, using the MNK variable is even more powerful: generate M,N,K-combinations for each comma
# separated group e.g., "1, 2, 3" gnerates (1,1,1), (2,2,2), and (3,3,3). This way a heterogeneous
# set can be generated e.g., "1 2, 3" generates (1,1,1), (1,1,2), (1,2,1), (1,2,2), (2,1,1), (2,1,2)
# (2,2,1) out of the first group, and a (3,3,3) for the second group (which contains just 3).
MNK ?= $(shell seq -s, 1 5)

# limit to certain code path(s)
SSE ?= 0
AVX ?= 0

# Embed InterProcedural Optimization information into libraries
IPO ?= 0

# Use assembly kernel generator
GENASM ?= 1

# Specify an alignment (Bytes)
ALIGNMENT ?= 64

# Use aligned Store and/or aligned Load instructions
ALIGNED_STORES ?= 0
ALIGNED_LOADS ?= 0

# THRESHOLD problem size (M x N x K); determines when to use BLAS 
THRESHOLD ?= $(shell echo $$((24 * 24 * 24)))

# SPARSITY = (LIBXSMM_MAX_M * LIBXSMM_MAX_M * LIBXSMM_MAX_M) / LIBXSMM_MAX_MNK
# Use binary search in auto-dispatch when SPARSITY exceeds the given value.
# With SPARSITY < 1, the binary search is enabled by default (no threshold).
SPARSITY ?= 2

ROOTDIR ?= .
SCRDIR = $(ROOTDIR)/scripts
BLDDIR = $(ROOTDIR)/build
INCDIR = $(ROOTDIR)/include
SRCDIR = $(ROOTDIR)/src
LIBDIR = $(ROOTDIR)/lib

LIB_HST ?= $(LIBDIR)/intel64/libxsmm.a
LIB_MIC ?= $(LIBDIR)/mic/libxsmm.a
HEADER = $(INCDIR)/libxsmm.h
MAIN = $(SRCDIR)/libxsmm.c

# prefer the Intel compiler
ifneq ($(shell which icc 2> /dev/null),)
	CC := icc
	AR := xiar
	FLAGS := -Wall -fPIC -fno-alias -ansi-alias -mkl=sequential -DNDEBUG
	ifneq ($(IPO),0)
		FLAGS += -ipo
	endif
	CFLAGS := $(FLAGS) -std=c99 -O3 -offload-option,mic,compiler,"-O2 -opt-assume-safe-padding"
	CFLMIC := $(FLAGS) -std=c99 -O2 -mmic -opt-assume-safe-padding
	ifneq ($(shell which icpc 2> /dev/null),)
		CXX := icpc
		CXXFLAGS := $(FLAGS) -O3 -offload-option,mic,compiler,"-O2 -opt-assume-safe-padding"
		CXXFLMIC := $(FLAGS) -O2 -mmic -opt-assume-safe-padding
	endif
	ifeq ($(AVX),1)
		CFLAGS += -xAVX
		CXXFLAGS += -xAVX
	else ifeq ($(AVX),2)
		CFLAGS += -xCORE-AVX2
		CXXFLAGS += -xCORE-AVX2
	else ifeq ($(AVX),3)
		CFLAGS += -xCOMMON-AVX512
		CXXFLAGS += -xCOMMON-AVX512
	else ifneq ($(SSE),0)
		CFLAGS += -xSSE3
		CXXFLAGS += -xSSE3
	else
		CFLAGS += -xHost
		CXXFLAGS += -xHost
	endif
else ifneq ($(shell which gcc 2> /dev/null),)
	CC := gcc
	FLAGS := -Wall -O2 -DNDEBUG
	ifneq ($(IPO),0)
		FLAGS += -flto
	endif
	CFLAGS := $(FLAGS) -std=c99
	ifneq ($(shell which g++ 2> /dev/null),)
		CXX := g++
		CXXFLAGS := $(FLAGS) 
	endif
	ifeq ($(AVX),1)
		CFLAGS += -mavx
		CXXFLAGS += -mavx
	else ifeq ($(AVX),2)
		CFLAGS += -mavx2
		CXXFLAGS += -mavx2
	else ifeq ($(AVX),3)
		CFLAGS += -mavx512f
		CXXFLAGS += -mavx512f
	else ifneq ($(SSE),0)
		CFLAGS += -msse3
		CXXFLAGS += -msse3
	else
		CFLAGS += -march=native
		CXXFLAGS += -march=native
	endif
endif

ifeq ($(CXX),)
	CXX := $(CC)
endif
ifeq ($(CC),)
	CC := $(CXX)
endif
ifeq ($(CFLAGS),)
	CFLAGS := $(CXXFLAGS)
endif
ifeq ($(CFLMIC),)
	CFLMIC := $(CFLAGS)
endif
ifeq ($(CXXFLAGS),)
	CXXFLAGS := $(CFLAGS)
endif
ifeq ($(CXXFLMIC),)
	CXXFLMIC := $(CXXFLAGS)
endif

MKL_DIRECT := 0
ifneq ($(MKL_DIRECT),0)
	CFLAGS := -DMKL_DIRECT_CALL_SEQ
	CXXFLAGS := -DMKL_DIRECT_CALL_SEQ
	ifneq ($(MKL_DIRECT),1)
		CFLMIC := -DMKL_DIRECT_CALL_SEQ
		CXXFLMIC := -DMKL_DIRECT_CALL_SEQ
	endif
endif

ifeq ($(AVX),1)
	GENTARGET := snb
else ifeq ($(AVX),2)
	GENTARGET := hsw
else ifeq ($(AVX),3)
	GENTARGET := knl
else ifneq ($(SSE),0)
	GENTARGET := wsm
else
	GENTARGET := noarch
endif

ifneq ("$(M)$(N)$(K)","")
	INDICES ?= $(shell python $(SCRDIR)/libxsmm_utilities.py -2 $(words $(M)) $(words $(N)) $(M) $(N) $(K))
else
	INDICES ?= $(shell python $(SCRDIR)/libxsmm_utilities.py -1 '$(MNK)')
endif
NINDICES := $(words $(INDICES))

SRCFILES = $(addprefix $(SRCDIR)/,$(patsubst %,mm_%.c,$(INDICES)))
SRCFILES_GEN = $(patsubst %,$(SRCDIR)/%,GeneratorDriver.cpp GeneratorCSC.cpp GeneratorDense.cpp ReaderCSC.cpp)
OBJFILES_GEN = $(patsubst %,$(BLDDIR)/intel64/%.o,$(basename $(notdir $(SRCFILES_GEN))))
OBJFILES_HST = $(patsubst %,$(BLDDIR)/intel64/mm_%.o,$(INDICES))
OBJFILES_MIC = $(patsubst %,$(BLDDIR)/mic/mm_%.o,$(INDICES))

.PHONY: lib_all
lib_all: lib_hst lib_mic

.PHONY: header
header: $(HEADER)
$(HEADER): $(SRCDIR)/libxsmm.0.h $(SRCDIR)/libxsmm.1.h $(SRCDIR)/libxsmm.2.h
	@cat $(SRCDIR)/libxsmm.0.h > $@
	@python $(SCRDIR)/libxsmm_impl_mm.py $(ROW_MAJOR) $(ALIGNED_STORES) $(ALIGNED_LOADS) $(ALIGNMENT) $(THRESHOLD) $(INDICES) >> $@
	@echo >> $@
	@cat $(SRCDIR)/libxsmm.1.h >> $@
	@echo >> $@
	@python $(SCRDIR)/libxsmm_interface.py $(INDICES) >> $@
	@cat $(SRCDIR)/libxsmm.2.h >> $@

ifneq ($(GENASM),0)
.PHONY: compile_gen
compile_gen: $(SRCFILES_GEN)
$(BLDDIR)/intel64/%.o: $(SRCDIR)/%.cpp
	@mkdir -p $(BLDDIR)/intel64
	$(CXX) -c $< -o $@
.PHONY: generator
generator: $(OBJFILES_GEN)
$(SCRDIR)/generator: $(OBJFILES_GEN)
	$(CXX) $(OBJFILES_GEN) -o $@
endif

.PHONY: sources
sources: $(SRCFILES)
ifeq ($(GENASM),0)
$(SRCDIR)/%.c: $(HEADER)
else
$(SRCDIR)/%.c: $(HEADER) $(SCRDIR)/generator
endif
	$(eval MVALUE := $(shell echo $* | cut --output-delimiter=' ' -d_ -f2))
	$(eval NVALUE := $(shell echo $* | cut --output-delimiter=' ' -d_ -f3))
	$(eval KVALUE := $(shell echo $* | cut --output-delimiter=' ' -d_ -f4))
ifneq ($(ROW_MAJOR),0) # row-major
	$(eval MVALUE2 := $(NVALUE))
	$(eval NVALUE2 := $(MVALUE))
else # column-major
	$(eval MVALUE2 := $(MVALUE))
	$(eval NVALUE2 := $(NVALUE))
endif
ifneq ($(ALIGNED_STORES),0) # aligned stores
	$(eval LDCDP := $(shell python $(SCRDIR)/libxsmm_utilities.py 8 $(MVALUE2) $(ALIGNMENT) $(ALIGNED_STORES)))
	$(eval LDCSP := $(shell python $(SCRDIR)/libxsmm_utilities.py 4 $(MVALUE2) $(ALIGNMENT) $(ALIGNED_STORES)))
else # unaligned stores
	$(eval LDCDP := $(MVALUE2))
	$(eval LDCSP := $(MVALUE2))
endif
	$(eval LDA := $(MVALUE2))
	$(eval LDB := $(KVALUE))
ifeq ($(GENASM),0)
	@python $(SCRDIR)/libxsmm_impl_mm.py $(ROW_MAJOR) $(ALIGNED_STORES) $(ALIGNED_LOADS) $(ALIGNMENT) -3 $(MVALUE) $(NVALUE) $(KVALUE) > $@
else
	@echo "#include <libxsmm.h>" > $@
	@if [[ ( 0 == $$(($(NVALUE) % 3)) && "knl" != $(GENTARGET) ) || ( 30 -ge $(NVALUE) && "knl" == $(GENTARGET) ) ]]; then echo "#define LIBXSMM_GENTARGET_$(GENTARGET)" >> $@; fi
	@if [[ 30 -ge $(NVALUE) ]]; then echo "#define LIBXSMM_GENTARGET_knc" >> $@; fi
	@echo >> $@
	@echo >> $@
ifeq ($(GENTARGET),noarch)
	@if [[ 0 == $$(($(NVALUE) % 3)) ]]; then \
		PS4=''; set -x; \
		$(SCRDIR)/generator dense $@ libxsmm_d$(basename $(notdir $@))_wsm $(MVALUE2) $(NVALUE2) $(KVALUE) $(LDA) $(LDB) $(LDCDP) 0 $(ALIGNED_STORES) 1 wsm nopf DP; \
		$(SCRDIR)/generator dense $@ libxsmm_s$(basename $(notdir $@))_wsm $(MVALUE2) $(NVALUE2) $(KVALUE) $(LDA) $(LDB) $(LDCSP) 0 $(ALIGNED_STORES) 1 wsm nopf SP; \
		$(SCRDIR)/generator dense $@ libxsmm_d$(basename $(notdir $@))_snb $(MVALUE2) $(NVALUE2) $(KVALUE) $(LDA) $(LDB) $(LDCDP) 0 $(ALIGNED_STORES) 1 snb nopf DP; \
		$(SCRDIR)/generator dense $@ libxsmm_s$(basename $(notdir $@))_snb $(MVALUE2) $(NVALUE2) $(KVALUE) $(LDA) $(LDB) $(LDCSP) 0 $(ALIGNED_STORES) 1 snb nopf SP; \
		$(SCRDIR)/generator dense $@ libxsmm_d$(basename $(notdir $@))_hsw $(MVALUE2) $(NVALUE2) $(KVALUE) $(LDA) $(LDB) $(LDCDP) 0 $(ALIGNED_STORES) 1 hsw nopf DP; \
		$(SCRDIR)/generator dense $@ libxsmm_s$(basename $(notdir $@))_hsw $(MVALUE2) $(NVALUE2) $(KVALUE) $(LDA) $(LDB) $(LDCSP) 0 $(ALIGNED_STORES) 1 hsw nopf SP; \
		false && $(SCRDIR)/generator dense $@ libxsmm_d$(basename $(notdir $@))_hsw $(MVALUE2) $(NVALUE2) $(KVALUE) $(LDA) $(LDB) $(LDCDP) 0 $(ALIGNED_STORES) 1 knl nopf DP; \
		false && $(SCRDIR)/generator dense $@ libxsmm_s$(basename $(notdir $@))_hsw $(MVALUE2) $(NVALUE2) $(KVALUE) $(LDA) $(LDB) $(LDCSP) 0 $(ALIGNED_STORES) 1 knl nopf SP; \
	fi
else
	@if [[ ( 0 == $$(($(NVALUE) % 3)) && "knl" != $(GENTARGET) ) || ( 30 -ge $(NVALUE) && "knl" == $(GENTARGET) ) ]]; then \
		PS4=''; set -x; \
		$(SCRDIR)/generator dense $@ libxsmm_d$(basename $(notdir $@))_$(GENTARGET) $(MVALUE2) $(NVALUE2) $(KVALUE) $(LDA) $(LDB) $(LDCDP) 0 $(ALIGNED_STORES) 1 $(GENTARGET) nopf DP; \
		$(SCRDIR)/generator dense $@ libxsmm_s$(basename $(notdir $@))_$(GENTARGET) $(MVALUE2) $(NVALUE2) $(KVALUE) $(LDA) $(LDB) $(LDCSP) 0 $(ALIGNED_STORES) 1 $(GENTARGET) nopf SP; \
	fi
endif
	@if [[ 30 -ge $(NVALUE) ]]; then \
		PS4=''; set -x; \
		$(SCRDIR)/generator dense $@ libxsmm_d$(basename $(notdir $@))_knc $(MVALUE2) $(NVALUE2) $(KVALUE) $(LDA) $(LDB) $(LDCDP) 0 $(ALIGNED_STORES) 1 knc nopf DP; \
		$(SCRDIR)/generator dense $@ libxsmm_s$(basename $(notdir $@))_knc $(MVALUE2) $(NVALUE2) $(KVALUE) $(LDA) $(LDB) $(LDCSP) 0 $(ALIGNED_STORES) 1 knc nopf SP; \
	fi
	@sed -i'' \
		-e 's/void libxsmm_/LIBXSMM_INLINE LIBXSMM_TARGET(mic) void libxsmm_/' \
		-e 's/#ifndef NDEBUG/#ifdef LIBXSMM_NEVER_DEFINED/' \
		-e '/#pragma message ("KERNEL COMPILATION ERROR in: " __FILE__)/d' \
		-e '/#error No kernel was compiled, lacking support for current architecture?/d' \
		-e '/#pragma message ("KERNEL COMPILATION WARNING: compiling .\+ code on .\+ or newer architecture: " __FILE__)/d' \
		$@
	@python $(SCRDIR)/libxsmm_impl_mm.py $(ROW_MAJOR) $(ALIGNED_STORES) $(ALIGNED_LOADS) $(ALIGNMENT) 0 $(MVALUE) $(NVALUE) $(KVALUE) >> $@
endif

.PHONY: main
main: $(MAIN)
$(MAIN): $(HEADER)
	@python $(SCRDIR)/libxsmm_dispatch.py $(THRESHOLD) $(SPARSITY) $(INDICES) > $@

.PHONY: compile_mic
compile_mic: $(OBJFILES_MIC)
$(BLDDIR)/mic/%.o: $(SRCDIR)/%.c $(HEADER) $(SRCDIR)/libxsmm_isa.h
	@mkdir -p $(BLDDIR)/mic
	$(CC) $(CFLMIC) -I$(INCDIR) -c $< -o $@
$(BLDDIR)/mic/%.o: $(SRCDIR)/%.cpp $(HEADER) $(SRCDIR)/libxsmm_isa.h
	@mkdir -p $(BLDDIR)/mic
	$(CXX) $(CXXFLMIC) -I$(INCDIR) -c $< -o $@

.PHONY: compile_hst
compile_hst: $(OBJFILES_HST)
$(BLDDIR)/intel64/%.o: $(SRCDIR)/%.c $(HEADER) $(SRCDIR)/libxsmm_isa.h
	@mkdir -p $(BLDDIR)/intel64
	$(CC) $(CFLAGS) -I$(INCDIR) -c $< -o $@
$(BLDDIR)/intel64/%.o: $(SRCDIR)/%.cpp $(HEADER) $(SRCDIR)/libxsmm_isa.h
	@mkdir -p $(BLDDIR)/intel64
	$(CXX) $(CXXFLAGS) -I$(INCDIR) -c $< -o $@

.PHONY: lib_mic
lib_mic: $(LIB_MIC)
ifeq ($(origin NO_MAIN), undefined)
$(LIB_MIC): $(OBJFILES_MIC) $(patsubst $(SRCDIR)/%.c,$(BLDDIR)/mic/%.o,$(MAIN))
else
$(LIB_MIC): $(OBJFILES_MIC)
endif
	@mkdir -p $(LIBDIR)/mic
	$(AR) -rs $@ $^

.PHONY: lib_hst
lib_hst: $(LIB_HST)
ifeq ($(origin NO_MAIN), undefined)
$(LIB_HST): $(OBJFILES_HST) $(patsubst $(SRCDIR)/%,$(BLDDIR)/intel64/%.o,$(basename $(MAIN)))
else
$(LIB_HST): $(OBJFILES_HST)
endif
	@mkdir -p $(LIBDIR)/intel64
	$(AR) -rs $@ $^

.PHONY: samples
samples: blas smm dispatched inlined specialized

.PHONY: blas
blas: lib_hst
	@cd samples/blas && $(MAKE)
.PHONY: blas_hst
blas_hst: lib_hst
	@cd samples/blas && $(MAKE) OFFLOAD=0
.PHONY: blas_mic
blas_mic: lib_mic
	@cd samples/blas && $(MAKE) MIC=1

.PHONY: smm
smm: lib_hst
	@cd samples/cp2k && $(MAKE)
.PHONY: smm_hst
smm_hst: lib_hst
	@cd samples/cp2k && $(MAKE) OFFLOAD=0
.PHONY: smm_mic
smm_mic: lib_mic
	@cd samples/cp2k && $(MAKE) MIC=1

.PHONY: dispatched
dispatched: lib_hst
	@cd samples/dispatched && $(MAKE)
.PHONY: dispatched_hst
dispatched_hst: lib_hst
	@cd samples/dispatched && $(MAKE) OFFLOAD=0
.PHONY: dispatched_mic
dispatched_mic: lib_mic
	@cd samples/dispatched && $(MAKE) MIC=1

.PHONY: inlined
inlined: lib_hst
	@cd samples/inlined && $(MAKE)
.PHONY: inlined_hst
inlined_hst: lib_hst
	@cd samples/inlined && $(MAKE) OFFLOAD=0
.PHONY: inlined_mic
inlined_mic: lib_mic
	@cd samples/inlined && $(MAKE) MIC=1

.PHONY: specialized
specialized: lib_hst
	@cd samples/specialized && $(MAKE)
.PHONY: specialized_hst
specialized_hst: lib_hst
	@cd samples/specialized && $(MAKE) OFFLOAD=0
.PHONY: specialized_mic
specialized_mic: lib_mic
	@cd samples/specialized && $(MAKE) MIC=1

.PHONY: test
test: samples/cp2k/smm-test.txt
samples/cp2k/smm-test.txt: samples/cp2k/smm-test.sh smm
	@samples/cp2k/smm-test.sh > $@

.PHONY: drytest
drytest: samples/cp2k/smm-test.sh
samples/cp2k/smm-test.sh:
	@echo "#!/bin/bash" > $@
	@echo >> $@
	@echo "HERE=\$$(cd \$$(dirname \$$0); pwd -P)" >> $@
	@echo >> $@
	@echo >> $@
	@echo "NRUN=1" >> $@
	@echo "for RUN in $(INDICES) ; do" >> $@
	@echo "  MVALUE=\$$(echo \$${RUN} | cut --output-delimiter=' ' -d_ -f1)" >> $@
	@echo "  NVALUE=\$$(echo \$${RUN} | cut --output-delimiter=' ' -d_ -f2)" >> $@
	@echo "  KVALUE=\$$(echo \$${RUN} | cut --output-delimiter=' ' -d_ -f3)" >> $@
	@echo "  >&2 echo \"Test \$${NRUN} of $(NINDICES) (M=\$${MVALUE} N=\$${NVALUE} K=\$${KVALUE})\"" >> $@
	@echo "  \$${HERE}/smm.sh \$${MVALUE} 0 0 \$${NVALUE} \$${KVALUE}" >> $@
	@echo "  echo" >> $@
	@echo "  NRUN=\$$((NRUN + 1))" >> $@
	@echo "done" >> $@
	@echo >> $@
	@chmod +x $@

.PHONY: clean
clean:
	@rm -rf $(BLDDIR)
	@rm -f samples/cp2k/smm-test-avg.dat
	@rm -f samples/cp2k/smm-test-cdf.dat
	@rm -f samples/cp2k/smm-test.dat
	@rm -f $(SCRDIR)/generator
	@rm -f $(SCRDIR)/generator.exe
	@rm -f $(SRCDIR)/mm_*_*_*.c
	@rm -f $(ROOTDIR)/*/*/*~
	@rm -f $(ROOTDIR)/*/*~
	@rm -f $(ROOTDIR)/*~
	@rm -f $(MAIN)

.PHONY: realclean
realclean: clean
	@rm -rf $(LIBDIR)
	@rm -f samples/cp2k/smm-test.txt
	@rm -f samples/cp2k/smm-test.sh
	@rm -f $(HEADER)

.PHONY: install
install: lib_all samples clean
