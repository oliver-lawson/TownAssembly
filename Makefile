SRC_DIR := src
BUILD_DIR := build

# finds all .asm files and builds each into its own binary
SRCS := $(filter-out $(SRC_DIR)/%.inc.asm, $(wildcard $(SRC_DIR)/*.asm))
BINS := $(patsubst $(SRC_DIR)/%.asm,$(BUILD_DIR)/%,$(SRCS))
INCS := $(wildcard $(SRC_DIR)/*.inc.asm)

CFLAGS := -no-pie
LDLIBS := -lSDL2

all: $(BINS)

$(BUILD_DIR)/%: $(SRC_DIR)/%.asm $(INCS) | $(BUILD_DIR)
	nasm -f elf64 -g -F dwarf -i $(SRC_DIR)/ $< -o $(BUILD_DIR)/$*.o
	gcc $(CFLAGS) $(BUILD_DIR)/$*.o -o $@ $(LDLIBS)
	rm -f $(BUILD_DIR)/$*.o

# ensure build directory exists
$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

# run specific binary: make run-binaryname
run-%: $(BUILD_DIR)/%
	./$<

clean:
	rm -rf $(BUILD_DIR)