package profile

import (
	"encoding/json"
	"io"
)

// SpeedscopeFile 适配 speedscope 的 sampled profile 格式
// Schema 参考: https://github.com/jlfwong/speedscope/blob/main/src/lib/file-format-spec.ts
type SpeedscopeFile struct {
	Schema   string             `json:"$schema"`
	Shared   SpeedscopeShared   `json:"shared"`
	Profiles []SpeedscopeProfile `json:"profiles"`
}

// SpeedscopeShared 共享 frame 表
type SpeedscopeShared struct {
	Frames []SpeedscopeFrame `json:"frames"`
}

// SpeedscopeFrame 一个函数帧
type SpeedscopeFrame struct {
	Name string `json:"name"`
}

// SpeedscopeProfile 单个采样 profile
type SpeedscopeProfile struct {
	Type       string  `json:"type"`       // 固定 "sampled"
	Name       string  `json:"name"`       // 显示在 speedscope 顶部
	Unit       string  `json:"unit"`       // "samples" / "none" / "nanoseconds" / "microseconds" / "milliseconds" / "seconds" / "bytes"
	StartValue int     `json:"startValue"` // 起始累计权重
	EndValue   int     `json:"endValue"`   // 结束累计权重
	Samples    [][]int `json:"samples"`    // 每个元素是一个 frame index 数组（从底到顶）
	Weights    []int   `json:"weights"`    // 每个采样的权重
}

// ToSpeedscope 将折叠栈转换为 speedscope sampled 格式
// profileName 显示在 speedscope 顶部
func ToSpeedscope(stacks []FoldedStack, profileName string) *SpeedscopeFile {
	frameIndex := make(map[string]int)
	frames := []SpeedscopeFrame{}
	samples := make([][]int, 0, len(stacks))
	weights := make([]int, 0, len(stacks))

	totalWeight := 0
	for _, s := range stacks {
		sample := make([]int, len(s.Frames))
		for i, name := range s.Frames {
			idx, ok := frameIndex[name]
			if !ok {
				idx = len(frames)
				frameIndex[name] = idx
				frames = append(frames, SpeedscopeFrame{Name: name})
			}
			sample[i] = idx
		}
		samples = append(samples, sample)
		weights = append(weights, s.Count)
		totalWeight += s.Count
	}

	return &SpeedscopeFile{
		Schema: "https://www.speedscope.app/file-format-schema.json",
		Shared: SpeedscopeShared{Frames: frames},
		Profiles: []SpeedscopeProfile{
			{
				Type:       "sampled",
				Name:       profileName,
				Unit:       "samples",
				StartValue: 0,
				EndValue:   totalWeight,
				Samples:    samples,
				Weights:    weights,
			},
		},
	}
}

// WriteJSON 将 speedscope 文件以 JSON 写入 w
func (f *SpeedscopeFile) WriteJSON(w io.Writer) error {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(f)
}
