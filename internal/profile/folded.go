// Package profile 处理折叠栈解析与 speedscope 格式转换
package profile

import (
	"bufio"
	"fmt"
	"io"
	"strconv"
	"strings"
)

// FoldedStack 一条折叠栈记录
type FoldedStack struct {
	Frames []string // 调用栈：[main, foo, bar]，main 在最底
	Count  int      // 采样命中次数
}

// ParseFolded 解析折叠栈文本，每行格式：`a;b;c 123`
// 行尾可带 \r\n，空行跳过
func ParseFolded(r io.Reader) ([]FoldedStack, error) {
	var result []FoldedStack
	scanner := bufio.NewScanner(r)
	// 单行最大 16MB，应对极深调用栈
	scanner.Buffer(make([]byte, 1024*1024), 16*1024*1024)
	for scanner.Scan() {
		line := strings.TrimRight(scanner.Text(), "\r")
		if line == "" {
			continue
		}
		// 最后一个空格分隔栈与计数（栈中函数名不含空格）
		idx := strings.LastIndexByte(line, ' ')
		if idx < 0 {
			return nil, fmt.Errorf("invalid folded line (no count): %q", line)
		}
		stackStr := line[:idx]
		countStr := line[idx+1:]
		count, err := strconv.Atoi(countStr)
		if err != nil {
			return nil, fmt.Errorf("invalid count %q: %w", countStr, err)
		}
		if count <= 0 {
			continue // 跳过 0 计数
		}
		frames := strings.Split(stackStr, ";")
		result = append(result, FoldedStack{Frames: frames, Count: count})
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return result, nil
}

// SampleCount 返回所有采样的总次数
func SampleCount(stacks []FoldedStack) int {
	total := 0
	for _, s := range stacks {
		total += s.Count
	}
	return total
}
