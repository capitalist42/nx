defmodule Nx.Tensor do
  @moduledoc """
  The tensor struct and the behaviour for backends.

  `Nx.Tensor` is a generic container for multidimensional data structures.
  It contains the tensor type, shape, and names. The data itself is a
  struct that points to a backend responsible for controlling the data.
  The backend behaviour is described in `Nx.Backend`.

  The tensor has the following fields:

    * `:data` - the tensor backend and its data
    * `:shape` - the tensor shape
    * `:type` - the tensor type
    * `:names` - the tensor names
    * `:vectorized_axes` - a tuple that encodes names and sizes for vectorization

  In general it is discouraged to access those fields directly. Use
  the functions in the `Nx` module instead. Backends have to access those
  fields but it cannot update them, except for the `:data` field itself.
  """

  @type data :: Nx.Backend.t()
  @type type :: Nx.Type.t()
  @type shape :: tuple()
  @type axis :: name | integer
  @type axes :: [axis]
  @type name :: atom

  @type t :: %Nx.Tensor{data: data, type: type, shape: shape, names: [name]}
  @type t(data) :: %Nx.Tensor{data: data, type: type, shape: shape, names: [name]}

  @enforce_keys [:type, :shape, :names]
  defstruct [:data, :type, :shape, :names, vectorized_axes: []]

  ## Access

  @behaviour Access

  @impl true
  def fetch(%Nx.Tensor{shape: {}} = tensor, _index) do
    raise ArgumentError,
          "cannot use the tensor[index] syntax on scalar tensor #{inspect(tensor)}"
  end

  def fetch(tensor, %Nx.Tensor{} = index),
    do: {:ok, fetch_axes(tensor, [{0, index}])}

  def fetch(tensor, index) when is_integer(index),
    do: {:ok, fetch_axes(tensor, [{0, index}])}

  def fetch(tensor, _.._//_ = range),
    do: {:ok, fetch_axes(tensor, [{0, range}])}

  def fetch(tensor, []),
    do: {:ok, tensor}

  def fetch(%{names: names} = tensor, [{_, _} | _] = keyword),
    do: {:ok, fetch_axes(tensor, with_names(keyword, names, []))}

  def fetch(tensor, [_ | _] = list),
    do: {:ok, fetch_axes(tensor, with_index(list, 0, []))}

  def fetch(_tensor, value) do
    raise """
    tensor[slice] expects slice to be one of:

      * an integer or a scalar tensor representing a zero-based index
      * a first..last range representing inclusive start-stop indexes
      * a list of integers and ranges
      * a keyword list of integers and ranges

    Got #{inspect(value)}
    """
  end

  defp with_index([h | t], i, acc), do: with_index(t, i + 1, [{i, h} | acc])
  defp with_index([], _i, acc), do: acc

  defp with_names([{k, v} | t], names, acc),
    do: with_names(t, names, [{Nx.Shape.find_name!(names, k), v} | acc])

  defp with_names([], _names, acc),
    do: acc

  defp fetch_axes(%Nx.Tensor{vectorized_axes: vectorized_axes, shape: shape} = tensor, axes) do
    rank = Nx.rank(shape)
    impl = Nx.Shared.impl!(tensor)
    {start, lengths, squeeze} = fetch_axes(rank - 1, axes, shape, [], [], [])

    offset = length(vectorized_axes)

    start = List.duplicate(0, offset) ++ start
    offset_shape = Keyword.values(vectorized_axes)
    lengths = offset_shape ++ lengths

    tensor = Nx.devectorize(tensor)

    %{tensor | shape: List.to_tuple(lengths)}
    |> impl.slice(tensor, start, lengths, List.duplicate(1, rank))
    |> Nx.vectorize(vectorized_axes)
    |> Nx.squeeze(axes: squeeze)
  end

  defp fetch_axes(axis, axes, shape, start, lengths, squeeze) when axis >= 0 do
    case List.keytake(axes, axis, 0) do
      {{^axis, %Nx.Tensor{} = index}, axes} ->
        fetch_axes(axis - 1, axes, shape, [index | start], [1 | lengths], [axis | squeeze])

      {{^axis, index}, axes} when is_integer(index) ->
        index = normalize_index(index, axis, shape)
        fetch_axes(axis - 1, axes, shape, [index | start], [1 | lengths], [axis | squeeze])

      {{^axis, first..last//step = range}, axes} ->
        first = normalize_index(first, axis, shape)
        last = normalize_index(last, axis, shape)

        if last < first or step != 1 do
          raise ArgumentError,
                "slicing a tensor requires a non-empty range with a step of 1, got: #{inspect(range)}"
        end

        len = last - first + 1
        fetch_axes(axis - 1, axes, shape, [first | start], [len | lengths], squeeze)

      {{^axis, value}, _} ->
        raise ArgumentError,
              "slicing a tensor on an axis requires an integer, a scalar tensor or a range, got: " <>
                inspect(value)

      nil ->
        fetch_axes(axis - 1, axes, shape, [0 | start], [elem(shape, axis) | lengths], squeeze)
    end
  end

  defp fetch_axes(_axis, [{axis, _} | _], shape, _start, _lengths, _squeeze) do
    raise ArgumentError,
          "unknown or duplicate axis #{axis} found when slicing shape #{inspect(shape)}"
  end

  defp fetch_axes(_axis, [], _shape, start, lengths, squeeze) do
    {start, lengths, squeeze}
  end

  defp normalize_index(index, axis, shape) do
    dim = elem(shape, axis)
    norm = if index < 0, do: dim + index, else: index

    if norm < 0 or norm >= dim do
      raise ArgumentError,
            "index #{index} is out of bounds for axis #{axis} in shape #{inspect(shape)}"
    end

    norm
  end

  @impl true
  def get_and_update(_tensor, _index, _update) do
    raise "Access.get_and_update/3 is not supported. Please use Nx.put_slice/3 instead"
  end

  @impl true
  def pop(_tensor, _index) do
    raise "Access.pop/2 is not yet supported by Nx.Tensor"
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(
          %{shape: shape, names: names, type: type, vectorized_axes: vectorized_axes} = tensor,
          opts
        ) do
      open = color("[", :list, opts)
      close = color("]", :list, opts)
      type = color(Nx.Type.to_string(type), :atom, opts)

      {vectorized_names, vectorized_sizes} = Enum.unzip(vectorized_axes)
      vectorized_shape_tuple = List.to_tuple(vectorized_sizes)

      vectorized_shape =
        if vectorized_axes == [] do
          empty()
        else
          concat([
            "vectorized",
            Nx.Shape.to_algebra(vectorized_shape_tuple, vectorized_names, open, close),
            line()
          ])
        end

      shape = Nx.Shape.to_algebra(shape, names, open, close)

      # TO-DO: this is not the right way, but helps validate results
      data = tensor.data.__struct__.inspect(Nx.devectorize(tensor), opts)

      inner =
        if data == empty() do
          concat([line(), vectorized_shape, type, shape, data])
        else
          concat([line(), vectorized_shape, type, shape, line(), data])
        end

      force_unfit(
        concat([
          color("#Nx.Tensor<", :map, opts),
          nest(inner, 2),
          line(),
          color(">", :map, opts)
        ])
      )
    end
  end
end
