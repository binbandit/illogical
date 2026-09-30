package mux

// Layout is a window's split tree. Leaves hold a block; inner nodes split
// their area between First and Second along Axis at Ratio.
type Layout struct {
	ID     string  `json:"id"`
	Block  string  `json:"block,omitempty"`
	Axis   string  `json:"axis,omitempty"`
	Ratio  float64 `json:"ratio,omitempty"`
	First  *Layout `json:"first,omitempty"`
	Second *Layout `json:"second,omitempty"`
}

func leaf(block string) *Layout { return &Layout{ID: NewID(), Block: block} }

func (n *Layout) clone() *Layout {
	if n == nil {
		return nil
	}
	return &Layout{ID: n.ID, Block: n.Block, Axis: n.Axis, Ratio: n.Ratio, First: n.First.clone(), Second: n.Second.clone()}
}

func (n *Layout) contains(block string) bool {
	if n == nil || block == "" {
		return false
	}
	return n.Block == block || n.First.contains(block) || n.Second.contains(block)
}

func (n *Layout) blocks() []string {
	if n == nil {
		return nil
	}
	if n.Block != "" {
		return []string{n.Block}
	}
	return append(n.First.blocks(), n.Second.blocks()...)
}

// remove deletes a leaf and collapses its parent split into the sibling.
func (n *Layout) remove(block string) *Layout {
	if n == nil || n.Block == block {
		return nil
	}
	if n.Block != "" {
		return n
	}
	n.First = n.First.remove(block)
	n.Second = n.Second.remove(block)
	if n.First == nil {
		return n.Second
	}
	if n.Second == nil {
		return n.First
	}
	return n
}

// insert splits target's leaf, placing block second.
func (n *Layout) insert(target, block, axis string) bool {
	if n == nil {
		return false
	}
	if n.Block == target {
		n.First, n.Second = leaf(target), leaf(block)
		n.Block, n.Axis, n.Ratio = "", axis, 0.5
		return true
	}
	return n.First.insert(target, block, axis) || n.Second.insert(target, block, axis)
}

func (n *Layout) replace(old, new string) {
	if n == nil {
		return
	}
	if n.Block == old {
		n.Block = new
	}
	n.First.replace(old, new)
	n.Second.replace(old, new)
}

func (n *Layout) resize(id string, ratio float64) bool {
	if n == nil {
		return false
	}
	if n.ID == id && n.Block == "" {
		n.Ratio = max(0.1, min(0.9, ratio))
		return true
	}
	return n.First.resize(id, ratio) || n.Second.resize(id, ratio)
}

func splitAxis(axis string) string {
	if axis == "vertical" {
		return "vertical"
	}
	return "horizontal"
}
