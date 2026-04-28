SRC_DIR := src
BUILD_DIR := build

# finds all .asm files and builds each into its own binary
SRCS := $(wildcard $(SRC_DIR)/*.asm)
BINS := $(patsubst $(SRC_DIR)/%.asm,$(BUILD_DIR)/%,$(SRCS))

all: $(BINS)

$(BUILD_DIR)/%: $(SRC_DIR)/%.asm | $(BUILD_DIR)
	nasm -f elf64 -g -F dwarf $< -o $(BUILD_DIR)/$*.o
	ld $(BUILD_DIR)/$*.o -o $@
	rm -f $(BUILD_DIR)/$*.o

# ensure build directory exists
$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

# run specific binary: make run-binaryname
run-%: $(BUILD_DIR)/%
	./$<

clean:
	rm -rf $(BUILD_DIR)