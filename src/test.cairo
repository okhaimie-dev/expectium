use traits::{Into, TryInto};
use debug::PrintTrait;
use expectium::config::{pack_order, unpack_order, Order};
use clone::Clone;
use array::ArrayTrait;

impl OrderPrint of PrintTrait<Order> {
    fn print(self: Order) {
        Into::<_, felt252>::into(self.order_id).print();
        Into::<_, felt252>::into(self.date).print();
        Into::<_, felt252>::into(self.amount).print();
        Into::<_, felt252>::into(self.price).print();
        Into::<_, felt252>::into(self.status).print();
    }
}

impl ArrayPrint of PrintTrait<Array<felt252>> {
    fn print(self: Array<felt252>) {
        let mut cloned = self.clone();
        loop {
            match cloned.pop_front() {
                Option::Some(v) => {
                    let unpacked_order: Order = unpack_order(v);
                    unpacked_order.print();
                },
                Option::None(()) => {
                    'ENDOFARRAY'.print();
                    break;
                }
            };
        };
    }
}

#[cfg(test)]
mod tests {
    use expectium::config::{pack_order, unpack_order, Order};
    use expectium::array::{_sort_orders_descending, _sort_orders_ascending};
    use traits::{Into, TryInto};
    use option::OptionTrait;
    use debug::PrintTrait;
    use super::OrderPrint;
    use array::ArrayTrait;

    #[test]
    #[available_gas(30000000)]
    fn test_packing() {
        let unpacked_order_id: u32 = 120_u32;
        let unpacked_date: u64 = 12718736211_u64;
        let unpacked_amount: u128 = 1391739747178378912341134_u128;
        let unpacked_price: u16 = 4388_u16;
        let unpacked_status: felt252 = 3;

        let sample_order: Order = Order {
            order_id : unpacked_order_id,
            date: unpacked_date,
            amount: unpacked_amount,
            price: unpacked_price,
            status: unpacked_status.try_into().unwrap()
        };
        let packed_order: felt252 = pack_order(sample_order);

        packed_order.print();

        let unpacked_order: Order = unpack_order(packed_order);

        unpacked_order.print();

        assert(unpacked_order_id == unpacked_order.order_id, 'orderid wrong');
        assert(unpacked_date == unpacked_order.date, 'orderid wrong');
        assert(unpacked_amount == unpacked_order.amount, 'orderid wrong');
        assert(unpacked_price == unpacked_order.price, 'orderid wrong');
        assert(unpacked_status.try_into().unwrap() == unpacked_order.status, 'orderid wrong');
    }

    #[test]
    #[available_gas(300000000)]
    fn test_ascending_sorting() {
        let sample_order_1: Order = Order {
            order_id : 1,
            date: 998,
            amount: 151,
            price: 100,
            status: 0.try_into().unwrap()
        };
        let sample_order_2: Order = Order {
            order_id : 2,
            date: 998,
            amount: 151,
            price: 50,
            status: 0.try_into().unwrap()
        };
        let sample_order_3: Order = Order {
            order_id : 3,
            date: 998,
            amount: 151,
            price: 20,
            status: 0.try_into().unwrap()
        };
        let sample_order_4: Order = Order {
            order_id : 4,
            date: 998,
            amount: 151,
            price: 200,
            status: 0.try_into().unwrap()
        };
        let sample_order_5: Order = Order {
            order_id : 5,
            date: 997,
            amount: 151,
            price: 200,
            status: 0.try_into().unwrap()
        };

        let mut unsorted_array: Array<felt252> = ArrayTrait::<felt252>::new();

        unsorted_array.append(pack_order(sample_order_1));
        unsorted_array.append(pack_order(sample_order_2));
        unsorted_array.append(pack_order(sample_order_3));
        unsorted_array.append(pack_order(sample_order_4));
        unsorted_array.append(pack_order(sample_order_5));

        let sorted_array: Array<felt252> = _sort_orders_ascending(unsorted_array);

        let first_element: felt252 = *sorted_array.at(0);
        let last_element: felt252 = *sorted_array.at(4);

        assert(unpack_order(first_element).order_id == 3, 'first elem wrong');
        assert(unpack_order(last_element).order_id == 4, 'last elem wrong');
    }

    #[test]
    #[available_gas(300000000)]
    fn test_descending_sorting() {
        let sample_order_1: Order = Order {
            order_id : 1,
            date: 998,
            amount: 151,
            price: 100,
            status: 0.try_into().unwrap()
        };
        let sample_order_2: Order = Order {
            order_id : 2,
            date: 998,
            amount: 151,
            price: 50,
            status: 0.try_into().unwrap()
        };
        let sample_order_3: Order = Order {
            order_id : 3,
            date: 998,
            amount: 151,
            price: 20,
            status: 0.try_into().unwrap()
        };
        let sample_order_4: Order = Order {
            order_id : 4,
            date: 998,
            amount: 151,
            price: 200,
            status: 0.try_into().unwrap()
        };
        let sample_order_5: Order = Order {
            order_id : 5,
            date: 997,
            amount: 151,
            price: 200,
            status: 0.try_into().unwrap()
        };

        let mut unsorted_array: Array<felt252> = ArrayTrait::<felt252>::new();

        unsorted_array.append(pack_order(sample_order_1));
        unsorted_array.append(pack_order(sample_order_2));
        unsorted_array.append(pack_order(sample_order_3));
        unsorted_array.append(pack_order(sample_order_4));
        unsorted_array.append(pack_order(sample_order_5));

        let sorted_array: Array<felt252> = _sort_orders_descending(unsorted_array);

        let first_element: felt252 = *sorted_array.at(0);
        let last_element: felt252 = *sorted_array.at(4);

        assert(unpack_order(first_element).order_id == 5, 'first elem wrong');
        assert(unpack_order(last_element).order_id == 3, 'last elem wrong');
    }
}