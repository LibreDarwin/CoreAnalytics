/*
 * The JSON type of Apple's C++ signatures, nlohmann::basic_json with its
 * default template arguments (the 10-parameter form of nlohmann 3.10).  Our
 * specialization only reproduces the object layout, a one-byte type tag and
 * an 8-byte value, so values cross the interface in both directions, and it
 * mangles like Apple's so the signatures (and arm64e vtable discriminators)
 * match.  Plain C++: tests/cxx_driver.cpp uses it too.
 *
 * Copyright (C) 2026, LibreDarwin
 * SPDX-License-Identifier: BSD-3-Clause
 */

#ifndef CA_NLOHMANN_JSON_H
#define CA_NLOHMANN_JSON_H

#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace nlohmann {
template <typename T, typename SFINAE> struct adl_serializer;
template <template <typename, typename, typename...> class ObjectType,
    template <typename, typename...> class ArrayType, class StringType,
    class BooleanType, class NumberIntegerType, class NumberUnsignedType,
    class NumberFloatType, template <typename> class AllocatorType,
    template <typename, typename> class JSONSerializer, class BinaryType>
class basic_json;

template <>
class basic_json<std::map, std::vector, std::string, bool, long long,
    unsigned long long, double, std::allocator, adl_serializer,
    std::vector<unsigned char>> {
public:
	enum class value_t : uint8_t {
		null, object, array, string, boolean, number_integer,
		number_unsigned, number_float, binary, discarded
	};
	using object_t = std::map<std::string, basic_json>;
	using array_t = std::vector<basic_json>;
	struct binary_t {	/* byte_container_with_subtype */
		std::vector<uint8_t> bytes;
		uint64_t subtype;
		bool has_subtype;
	};

	value_t m_type = value_t::null;
	union {
		object_t *object;
		array_t *array;
		std::string *string;
		binary_t *binary;
		bool boolean;
		long long number_integer;
		unsigned long long number_unsigned;
		double number_float;
	} m_value = {nullptr};

	basic_json() = default;
	basic_json(const basic_json &) = delete;
	basic_json(basic_json &&o) noexcept : m_type(o.m_type), m_value(o.m_value)
	{
		o.m_type = value_t::null;
		o.m_value.object = nullptr;
	}
	~basic_json()
	{
		switch (m_type) {
		case value_t::object: delete m_value.object; break;
		case value_t::array: delete m_value.array; break;
		case value_t::string: delete m_value.string; break;
		case value_t::binary: delete m_value.binary; break;
		default: break;
		}
	}
};
using json = basic_json<std::map, std::vector, std::string, bool, long long,
    unsigned long long, double, std::allocator, adl_serializer,
    std::vector<unsigned char>>;
}	/* namespace nlohmann */

#endif /* CA_NLOHMANN_JSON_H */
