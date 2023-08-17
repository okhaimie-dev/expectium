#[starknet::contract]
mod Orderbook {
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address, get_contract_address};
    use expectium::config::{Order, Asset, PlatformFees, FeeType, OrderStatus, StoreFelt252Array, 
            pack_order, unpack_order, safe_u16_to_u128, safe_u32_to_u128};
    use expectium::interfaces::{IOrderbook, IMarketDispatcher, IMarketDispatcherTrait, 
                                IERC20Dispatcher, IERC20DispatcherTrait, 
                                IDistributorDispatcher, IDistributorDispatcherTrait};
    use expectium::array::{_sort_orders_descending, _sort_orders_ascending};
    use array::{ArrayTrait, SpanTrait};
    use zeroable::Zeroable;
    use traits::{Into, TryInto};
    use clone::Clone;

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        OrderInserted: OrderInserted,
        Matched: Matched,
        Cancelled: Cancelled
    }

    #[derive(Drop, PartialEq, starknet::Event)]
    struct OrderInserted {
        maker: ContractAddress,
        asset: Asset,
        side: u8,
        amount: u256,
        price: u16,
        id: u32,
    }

    #[derive(Drop, PartialEq, starknet::Event)]
    struct Matched {
        maker_order_id: u32,
        maker: ContractAddress,
        asset: Asset,
        matched_amount: u256,
        price: u16,
        taker: ContractAddress,
        taker_side: u8
    }

    #[derive(Drop, PartialEq, starknet::Event)]
    struct Cancelled {
        id: u32,
        canceller: ContractAddress,
    }


    #[storage]
    struct Storage {
        market: ContractAddress, // connected market address
        quote_token: ContractAddress,
        distributor: ContractAddress, // Fee distributor contract // TODO !!
        happens: LegacyMap<u8, Array<felt252>>, // 0 buy 1 sell
        not: LegacyMap<u8, Array<felt252>>,
        market_makers: LegacyMap<u32, ContractAddress>, // Orderid -> Order owner
        order_count: u32,
        fees: PlatformFees, // 10000 bp. TODO: set fees
        is_emergency: bool,
        operator: ContractAddress, // Orderbook operator: Will have superrights until testnet.
    }

    #[constructor]
    fn constructor(ref self: ContractState, market: ContractAddress, operator: ContractAddress, quote_token: ContractAddress, distributor: ContractAddress) {
        self.operator.write(operator);
        self.market.write(market);
        self.quote_token.write(quote_token);
        self.distributor.write(distributor);

        IERC20Dispatcher { contract_address: quote_token }.approve(distributor, integer::BoundedInt::max());

        // TODO: approve quote token to distributor.
    }

    #[external(v0)]
    impl Orderbook of IOrderbook<ContractState> {
        fn get_order(self: @ContractState, asset: Asset, side: u8, order_id: u32) -> felt252 {
            assert(side < 2_u8, 'side wrong');
            _find_order(self, asset, side, order_id)
        }

        fn get_orders(self: @ContractState, asset: Asset, side: u8) -> Array<felt252> {
            assert(side < 2_u8, 'side wrong');
            match asset {
                Asset::Happens(()) => self.happens.read(side),
                Asset::Not(()) => self.not.read(side)
            }
        }

        fn market(self: @ContractState) -> ContractAddress {
            self.market.read()
        }

        fn operator(self: @ContractState) -> ContractAddress {
            self.operator.read()
        }

        fn distributor(self: @ContractState) -> ContractAddress {
            self.distributor.read()
        }

        fn get_order_owner(self: @ContractState, order_id: u32) -> ContractAddress {
            self.market_makers.read(order_id)
        }
        /////
        // asset: Alınacak asset
        // amount: alınacak asset miktarı
        // price: asset birim fiyatı
        /////
        fn insert_buy_order(ref self: ContractState, asset: Asset, amount: u256, price: u16) -> u32 {
            // Fiyat hesaplamada bi hata var
            // Burda düzenleme yapalım. Miktar yerine, fiyat ve harcanacak usdc gönderilsin? amounta gerek yok.
            assert(!_is_emergency(@self), 'in emergency');

            let caller = get_caller_address();
            let time = get_block_timestamp();

            assert(price > 0_u16, 'price zero');
            assert(price <= 10000_u16, 'price too high');

            assert(amount.high == 0, 'amount too high');

            let total_quote: u256 = amount * safe_u16_to_u128(price).into();
            assert(total_quote.high == 0, 'total_quote high');

            _receive_quote_token(ref self, caller, total_quote);

            let amount_low = amount.low; // alınacak asset miktarı
            // usdcleri mevcut emirlerle spend edicez. Bu şekilde alım yaparsak düşük fiyatla alınanlarda fazladan usdc kalabilir. Onları geri gönderelim.

            let (amount_left, spent_quote) = _match_incoming_buy_order(ref self, caller, asset, amount_low, price);
            // Dönen değerler. geriye kalan amount, spent_quote ise harcanana usdc.
            // Buradan sonra. kalan total_quote - spent_quote miktarı kadar emir girilmeli.
            if(spent_quote == total_quote) {
                return 0_u32;
            }
            let quote_left = total_quote - spent_quote; // Fix : 08.08.23 18:46 !! Selldede olabilir

            let order_id = self.order_count.read() + 1; // 0. order id boş bırakılıyor. 0 döner ise order tamamen eşleşti demek.
            self.order_count.write(order_id);

            let rest_amount: u128 = quote_left.low / safe_u16_to_u128(price).into();

            let mut order: Order = Order {
                order_id: order_id, date: time, amount: rest_amount, price: price, status: OrderStatus::Initialized(()) // Eğer amount değiştiyse partially filled yap.
            };

            let order_packed = pack_order(order);
            self.market_makers.write(order_id, caller);

            match asset {
                Asset::Happens(()) => {
                    let mut current_orders = self.happens.read(0_u8);
                    current_orders.append(order_packed);

                    let sorted_orders = _sort_orders(false, current_orders);
                    self.happens.write(0_u8, sorted_orders);
                },
                Asset::Not(()) => {
                    let mut current_orders = self.not.read(0_u8);
                    current_orders.append(order_packed);

                    let sorted_orders = _sort_orders(false, current_orders);
                    self.not.write(0_u8, sorted_orders);
                }
            };

            self.emit(Event::OrderInserted(
                OrderInserted { maker: caller, asset: asset, side:0_u8, amount: u256 { high: 0, low: rest_amount }, price: price, id: order_id}
            ));
            return order_id;
        }

        // Market order için price 1 gönderilebilir.
        fn insert_sell_order(ref self: ContractState, asset: Asset, amount: u256, price: u16) -> u32 {
            assert(!_is_emergency(@self), 'in emergency');

            let caller = get_caller_address();
            let time = get_block_timestamp();

            assert(price > 0_u16, 'price zero');    // Fiyat sadece 0 ile 10000 arasında olabilir. 10000 = 1$
            assert(price <= 10000_u16, 'price too high');

            assert(amount.high == 0, 'amount too high'); // sadece u128 supportu var
            let amount_low = amount.low;

            // asseti alalım
            _receive_assets(ref self, asset, caller, amount);

            // loop ile eşleşecek order var mı bakalım.
            let amount_left = _match_incoming_sell_order(ref self, caller, asset, amount_low, price);

            if(amount_left == 0) {
                return 0_u32;
            }

            let order_id = self.order_count.read() + 1; // 0. order id boş bırakılıyor. 0 döner ise order tamamen eşleşti demek.
            self.order_count.write(order_id);

            let mut order: Order = Order {
                order_id: order_id, date: time, amount: amount_left, price: price, status: OrderStatus::Initialized(()) // Eğer amount değiştiyse partially filled yap.
            };


            let order_packed = pack_order(order);
            self.market_makers.write(order_id, caller); // market maker olarak ekleyelim.

            match asset {
                Asset::Happens(()) => {
                    let mut current_orders = self.happens.read(1_u8);
                    current_orders.append(order_packed);

                    let sorted_orders = _sort_orders(true, current_orders);
                    self.happens.write(1_u8, sorted_orders);
                },
                Asset::Not(()) => {
                    let mut current_orders = self.not.read(1_u8);
                    current_orders.append(order_packed);

                    let sorted_orders = _sort_orders(true, current_orders);
                    self.not.write(1_u8, sorted_orders);
                }
            };

            self.emit(Event::OrderInserted(
                OrderInserted { maker: caller, asset: asset, side:1_u8, amount: u256 { high: 0, low: amount_left }, price: price, id: order_id}
            ));

            return order_id;
        }

         fn cancel_buy_order(ref self: ContractState, asset: Asset, order_id: u32) {
            assert(!_is_emergency(@self), 'in emergency');

            // TODO Kontrol
            let caller = get_caller_address();
            let order_owner: ContractAddress = self.market_makers.read(order_id);

            assert(order_owner == caller, 'owner wrong');

            _cancel_buy_order(ref self, order_owner, asset, order_id);

            self.emit(Event::Cancelled(
                Cancelled { id: order_id, canceller: caller }
            ));
         }

         fn cancel_sell_order(ref self: ContractState, asset: Asset, order_id: u32) {
            assert(!_is_emergency(@self), 'in emergency');
            // TODO Kontrol
            let caller = get_caller_address();

            let order_owner: ContractAddress = self.market_makers.read(order_id);

            // Order varmı kontrol etmeye gerek yok zaten caller ile kontrol ettik.
            assert(order_owner == caller, 'owner wrong');

            _cancel_sell_order(ref self, order_owner, asset, order_id);

            self.emit(Event::Cancelled(
                Cancelled { id: order_id, canceller: caller }
            ));
         }

         fn emergency_toggle(ref self: ContractState) {
            let caller = get_caller_address();
            assert(caller == self.operator.read(), 'only operator');

            self.is_emergency.write(!self.is_emergency.read())
         }

         fn refresh_distributor_approval(ref self: ContractState) {
            let caller = get_caller_address();
            assert(caller == self.operator.read(), 'only operator');

            let distributor = self.distributor.read();

            IERC20Dispatcher { contract_address: self.quote_token.read() }.approve(distributor, integer::BoundedInt::max());
         }

         fn set_fees(ref self: ContractState, fees: PlatformFees) {
            let caller = get_caller_address();
            assert(caller == self.operator.read(), 'only operator');

            assert(fees.taker <= 1000_u32, 'taker too much');
            assert(fees.maker <= 1000_u32, 'maker too much'); // Max fee %10

            self.fees.write(fees);
         }
    }

    fn _match_incoming_sell_order(ref self: ContractState, taker: ContractAddress, asset: Asset, amount: u128, price: u16) -> u128 {
        // TODO: Kontrol edilmeli.
        // Mevcut buy emirleriyle eşleştirelim.
        match asset {
            Asset::Happens(()) => {
                let mut amount_left = amount;
                let mut current_orders: Array<felt252> = self.happens.read(0_u8); // mevcut happens alış emirleri.

                if(current_orders.len() == 0) { // order yoksa direk emri girelim.
                    return amount_left;
                }

                let mut orders_modified = ArrayTrait::<felt252>::new();

                loop {
                    match current_orders.pop_front() {
                        Option::Some(v) => {
                            let mut order: Order = unpack_order(v);

                            if(amount_left == 0 || order.price < price) { // Satış geldiği için order fiyatı bu fiyattan yüksek veya eşitlerle eşleşmeli.
                                // bundan sonraki orderlar eşleşemez.
                                // sadece listeye geri ekleyip devam edelim.
                                orders_modified.append(v); // direk packli hali gönderelim.
                                continue;
                            };
                            let order_owner: ContractAddress = self.market_makers.read(order.order_id);

                            if(order.amount < amount_left) {
                                let spent_amount = order.amount;
                                amount_left -= spent_amount;

                                order.status = OrderStatus::Filled(());
                                order.amount = 0;

                                let (net_amount, maker_fee) = _apply_fee(@self, FeeType::Maker(()), u256 { high: 0, low: spent_amount }); // Gönderilecek net miktar ve fee hesaplayalım.
                                _transfer_assets(ref self, Asset::Happens(()), order_owner, net_amount); // Net miktarı emir sahibine gönderelim (maker)
                                _transfer_assets(ref self, Asset::Happens(()), self.operator.read(), maker_fee); // Fee miktarını operatore gönderelim

                                let quote_amount: u256 = u256 { high: 0, low: spent_amount } * safe_u16_to_u128(order.price).into(); // quote_amount hesaplayalım (price * amount)
                                let (net_amount, taker_fee) = _apply_fee(@self, FeeType::Taker(()), quote_amount); // emir giren satıcı olduğu için taker fee hesaplayalım
                                _transfer_quote_token(ref self, taker, net_amount); // net miktarı callera gönderelim.
                                //IDistributorDispatcher { contract_address: self.distributor.read() }.new_distribution(self.quote_token.read(), taker_fee); // kalan taker fee yi distribution registerlayalım.
                                _distribute_fees(@self, taker_fee);

                                self.emit(Event::Matched(
                                    Matched { maker_order_id: order.order_id, maker: order_owner, 
                                            asset: Asset::Happens(()), matched_amount:  u256 { high: 0, low : spent_amount},
                                            price: order.price, taker: taker, taker_side: 1_u8}
                                ));
                                // Orderı geri eklemeye gerek yok zaten tamamlandı.
                                continue;
                            };

                            if(order.amount >= amount_left) {
                                let spent_amount = amount_left;
                                amount_left = 0;

                                if(order.amount == spent_amount) {
                                    order.status = OrderStatus::Filled(());
                                    order.amount = 0;
                                    // amount 0 olunca eklemeye gerek yok.
                                } else {
                                    order.status = OrderStatus::PartiallyFilled(());
                                    order.amount -= spent_amount;
                                    orders_modified.append(pack_order(order)); // güncellenen orderi ekleyelim.
                                };

                                let (net_amount, maker_fee) = _apply_fee(@self, FeeType::Maker(()), u256 { high: 0, low: spent_amount }); // Satılacak amounttan fee hesaplayalım
                                _transfer_assets(ref self, Asset::Happens(()), order_owner, net_amount); // net miktarı emir sahibine gönderelim
                                _transfer_assets(ref self, Asset::Happens(()), self.operator.read(), maker_fee); // assetleri operatore gönderelim fee

                                // Yeni order girene(Taker), quote gönderelim.
                                let quote_amount: u256 = u256 { high: 0, low: spent_amount } * safe_u16_to_u128(order.price).into(); // quote hesaplayalım
                                let (net_amount, taker_fee) = _apply_fee(@self, FeeType::Taker(()), quote_amount); // fee hesaplayalım taker
                                _transfer_quote_token(ref self, taker, net_amount); // net miktarı emir girene gönderelim.
                                // IDistributorDispatcher { contract_address: self.distributor.read() }.new_distribution(self.quote_token.read(), taker_fee); // register fee distro
                                _distribute_fees(@self, taker_fee);

                                self.emit(Event::Matched(
                                    Matched { maker_order_id: order.order_id, maker: order_owner, 
                                            asset: Asset::Happens(()), matched_amount:  u256 { high: 0, low : spent_amount},
                                            price: order.price, taker: taker, taker_side: 1_u8}
                                ));
                            };
                        },
                        Option::None(()) => {
                            // burada order listesini güncelleyebiliriz.
                            let last_orders = orders_modified.clone();
                            let sorted_orders = _sort_orders(false, last_orders); // buy emirleri sıralanacağı için fiyat yukardan aşağı olmalı.
                            self.happens.write(0_u8, sorted_orders); // order listesi güncellendi.
                            break;
                        }
                    };
                };
                // en son harcanmayan miktar geri dönmeli.
                return amount_left;
            },
            Asset::Not(()) => { // TODO
                let mut amount_left = amount;
                let mut current_orders: Array<felt252> = self.not.read(0_u8); // mevcut not alış emirleri.

                if(current_orders.len() == 0) { // order yoksa direk emri girelim.
                    return amount_left;
                }

                let mut orders_modified = ArrayTrait::<felt252>::new();

                loop {
                    match current_orders.pop_front() {
                        Option::Some(v) => {
                            let mut order: Order = unpack_order(v);

                            if(amount_left == 0 || order.price < price) { // Satış geldiği için order fiyatı bu fiyattan yüksek veya eşitlerle eşleşmeli.
                                // bundan sonraki orderlar eşleşemez.
                                // sadece listeye geri ekleyip devam edelim.
                                orders_modified.append(v); // direk packli hali gönderelim.
                                continue;
                            };
                            let order_owner: ContractAddress = self.market_makers.read(order.order_id);

                            if(order.amount < amount_left) {
                                let spent_amount = order.amount;
                                amount_left -= spent_amount;

                                order.status = OrderStatus::Filled(());
                                order.amount = 0;

                                let (net_amount, maker_fee) = _apply_fee(@self, FeeType::Maker(()), u256 { high: 0, low: spent_amount });
                                _transfer_assets(ref self, Asset::Not(()), order_owner, net_amount);
                                _transfer_assets(ref self, Asset::Not(()), self.operator.read(), maker_fee); // TODO: Daha sonrasında assetide nft holderlarına dağıtacağız.

                                // Yeni order girene(Taker), quote gönderelim.
                                let quote_amount: u256 = u256 { high: 0, low: spent_amount } * safe_u16_to_u128(order.price).into(); // TODO: FEE
                                let (net_amount, taker_fee) = _apply_fee(@self, FeeType::Taker(()), quote_amount);
                                _transfer_quote_token(ref self, taker, net_amount);
                                //IDistributorDispatcher { contract_address: self.distributor.read() }.new_distribution(self.quote_token.read(), taker_fee); // register fee distro
                                _distribute_fees(@self, taker_fee);

                                self.emit(Event::Matched(
                                    Matched { maker_order_id: order.order_id, maker: order_owner, 
                                            asset: Asset::Not(()), matched_amount:  u256 { high: 0, low : spent_amount},
                                            price: order.price, taker: taker, taker_side: 1_u8}
                                ));
                                // Orderı geri eklemeye gerek yok zaten tamamlandı.
                                continue;
                            };

                            if(order.amount >= amount_left) {
                                let spent_amount = amount_left;
                                amount_left = 0;

                                if(order.amount == spent_amount) {
                                    order.status = OrderStatus::Filled(());
                                    order.amount = 0;
                                    // amount 0 olunca eklemeye gerek yok.
                                } else {
                                    order.status = OrderStatus::PartiallyFilled(());
                                    order.amount -= spent_amount;
                                    orders_modified.append(pack_order(order)); // güncellenen orderi ekleyelim.
                                };

                                let (net_amount, maker_fee) = _apply_fee(@self, FeeType::Maker(()), u256 { high: 0, low: spent_amount });
                                _transfer_assets(ref self, Asset::Not(()), order_owner, net_amount);
                                _transfer_assets(ref self, Asset::Not(()), self.operator.read(), maker_fee); // TODO: Daha sonrasında assetide nft holderlarına dağıtacağız.

                                // Yeni order girene(Taker), quote gönderelim.
                                let quote_amount: u256 = u256 { high: 0, low: spent_amount } * safe_u16_to_u128(order.price).into(); // TODO: FEE
                                let (net_amount, taker_fee) = _apply_fee(@self, FeeType::Taker(()), quote_amount);
                                _transfer_quote_token(ref self, taker, net_amount);
                                // IDistributorDispatcher { contract_address: self.distributor.read() }.new_distribution(self.quote_token.read(), taker_fee); // register fee distro
                                _distribute_fees(@self, taker_fee);

                                self.emit(Event::Matched(
                                    Matched { maker_order_id: order.order_id, maker: order_owner, 
                                            asset: Asset::Not(()), matched_amount:  u256 { high: 0, low : spent_amount},
                                            price: order.price, taker: taker, taker_side: 1_u8}
                                ));
                            };
                        },
                        Option::None(()) => {
                            // burada order listesini güncelleyebiliriz.
                            let last_orders = orders_modified.clone();
                            let sorted_orders = _sort_orders(false, last_orders); // buy emirleri sıralanacağı için fiyat yukardan aşağı olmalı.
                            self.not.write(0_u8, sorted_orders); // order listesi güncellendi.
                            break;
                        }
                    };
                };
                // en son harcanmayan miktar geri dönmeli.
                return amount_left;
            }
        }
    }

    // returns geri kalan amount, harcanan quote
    fn _match_incoming_buy_order(ref self: ContractState, taker: ContractAddress, asset: Asset, amount: u128, price: u16) -> (u128, u256) {
        match asset {
            Asset::Happens(()) => {
                let mut amount_left = amount;
                let mut quote_spent: u256 = 0;
                let mut current_orders: Array<felt252> = self.happens.read(1_u8); // mevcut satış emirleri

                if(current_orders.len() == 0) {
                    return (amount_left, 0); // emir yoksa direk emir gir.
                }

                let mut orders_modified = ArrayTrait::<felt252>::new();

                loop {
                    match current_orders.pop_front() {
                        Option::Some(v) => {
                            let mut order: Order = unpack_order(v);

                            if(amount_left == 0 || order.price > price) {
                                orders_modified.append(v);
                                continue;
                            };

                            let order_owner: ContractAddress = self.market_makers.read(order.order_id);

                            if(order.amount < amount_left) { // miktar yetersiz bir sonraki orderlarada bakacağız.
                                let spent_amount = order.amount; // bu orderda bu kadar alınacak
                                amount_left -= spent_amount;

                                order.status = OrderStatus::Filled(());
                                order.amount = 0;


                                let (net_amount, taker_fee) = _apply_fee(@self, FeeType::Taker(()), u256 { high: 0, low: spent_amount });
                                // transfer işlemleri
                                // 1) Emri girene orderdaki miktar kadar asset gönder
                                _transfer_assets(ref self, Asset::Happens(()), taker, net_amount);
                                _transfer_assets(ref self, Asset::Happens(()), self.operator.read(), taker_fee);
                                // 2) Emir sahibine quote token gönder.
                                let quote_amount: u256 = u256 { high: 0, low: spent_amount } * safe_u16_to_u128(order.price).into();
                                let (net_amount, maker_fee) = _apply_fee(@self, FeeType::Maker(()), quote_amount);
                                
                                quote_spent += quote_amount;

                                _transfer_quote_token(ref self, order_owner, net_amount);
                                // IDistributorDispatcher { contract_address: self.distributor.read() }.new_distribution(self.quote_token.read(), maker_fee);
                                _distribute_fees(@self, maker_fee);

                                self.emit(Event::Matched(
                                    Matched { maker_order_id: order.order_id, maker: order_owner, 
                                            asset: Asset::Happens(()), matched_amount:  u256 { high: 0, low : spent_amount},
                                            price: order.price, taker: taker, taker_side: 0_u8}
                                ));

                                continue;
                            };

                            if(order.amount >= amount_left) {
                                // bu order miktarı zaten yeterli. alım yapıp returnlicez
                                let spent_amount = amount_left;
                                amount_left = 0;
                                if(order.amount == spent_amount) {
                                    order.status = OrderStatus::Filled(());
                                    order.amount = 0;
                                } else {
                                    order.status = OrderStatus::PartiallyFilled(());
                                    order.amount -= spent_amount;
                                    orders_modified.append(pack_order(order));
                                };

                                let (net_amount, taker_fee) = _apply_fee(@self, FeeType::Taker(()), u256 { high: 0, low: spent_amount });

                                _transfer_assets(ref self, Asset::Happens(()), taker, net_amount);
                                _transfer_assets(ref self, Asset::Happens(()), self.operator.read(), taker_fee);

                                let quote_amount: u256 = u256 { high: 0, low: spent_amount } * safe_u16_to_u128(order.price).into();
                                let (net_amount, maker_fee) = _apply_fee(@self, FeeType::Maker(()), quote_amount);

                                
                                quote_spent += quote_amount;

                                _transfer_quote_token(ref self, order_owner, net_amount);
                                //IDistributorDispatcher { contract_address: self.distributor.read() }.new_distribution(self.quote_token.read(), maker_fee);
                                _distribute_fees(@self, maker_fee);

                                self.emit(Event::Matched(
                                    Matched { maker_order_id: order.order_id, maker: order_owner, 
                                            asset: Asset::Happens(()), matched_amount:  u256 { high: 0, low : spent_amount},
                                            price: order.price, taker: taker, taker_side: 0_u8}
                                ));
                            };
                        },
                        Option::None(()) => {
                            let last_orders = orders_modified.clone();
                            let sorted_orders = _sort_orders(true, last_orders);
                            self.happens.write(1_u8, sorted_orders);
                            break;
                        }
                    };
                };
                return (amount_left, quote_spent);
            },
            Asset::Not(()) => {
                let mut amount_left = amount;
                let mut quote_spent: u256 = 0;
                let mut current_orders: Array<felt252> = self.not.read(1_u8); // mevcut satış emirleri

                if(current_orders.len() == 0) {
                    return (amount_left, 0); // emir yoksa direk emir gir.
                }

                let mut orders_modified = ArrayTrait::<felt252>::new();

                loop {
                    match current_orders.pop_front() {
                        Option::Some(v) => {
                            let mut order: Order = unpack_order(v);

                            if(amount_left == 0 || order.price > price) {
                                orders_modified.append(v);
                                continue;
                            };

                            let order_owner: ContractAddress = self.market_makers.read(order.order_id);

                            if(order.amount < amount_left) { // miktar yetersiz bir sonraki orderlarada bakacağız.
                                let spent_amount = order.amount; // bu orderda bu kadar alınacak
                                amount_left -= spent_amount;

                                order.status = OrderStatus::Filled(());
                                order.amount = 0;

                                // transfer işlemleri

                                let (net_amount, taker_fee) = _apply_fee(@self, FeeType::Taker(()), u256 { high: 0, low: spent_amount });

                                // 1) Emri girene orderdaki miktar kadar asset gönder
                                _transfer_assets(ref self, Asset::Not(()), taker, net_amount);
                                _transfer_assets(ref self, Asset::Not(()), self.operator.read(), taker_fee);
                                // 2) Emir sahibine quote token gönder.

                                let quote_amount: u256 = u256 { high: 0, low: spent_amount } * safe_u16_to_u128(order.price).into();
                                let (net_amount, maker_fee) = _apply_fee(@self, FeeType::Maker(()), quote_amount);

                                quote_spent += quote_amount;

                                _transfer_quote_token(ref self, order_owner, net_amount);
                                // IDistributorDispatcher { contract_address: self.distributor.read() }.new_distribution(self.quote_token.read(), maker_fee);
                                _distribute_fees(@self, maker_fee);

                                self.emit(Event::Matched(
                                    Matched { maker_order_id: order.order_id, maker: order_owner, 
                                            asset: Asset::Not(()), matched_amount:  u256 { high: 0, low : spent_amount},
                                            price: order.price, taker: taker, taker_side: 0_u8}
                                ));
                                continue;
                            };

                            if(order.amount >= amount_left) {
                                // bu order miktarı zaten yeterli. alım yapıp returnlicez
                                let spent_amount = amount_left;
                                amount_left = 0;
                                if(order.amount == spent_amount) {
                                    order.status = OrderStatus::Filled(());
                                    order.amount = 0;
                                } else {
                                    order.status = OrderStatus::PartiallyFilled(());
                                    order.amount -= spent_amount;
                                    orders_modified.append(pack_order(order));
                                };

                                let (net_amount, taker_fee) = _apply_fee(@self, FeeType::Taker(()), u256 { high: 0, low: spent_amount });

                                _transfer_assets(ref self, Asset::Not(()), taker, net_amount);
                                _transfer_assets(ref self, Asset::Not(()), self.operator.read(), taker_fee);

                                let quote_amount: u256 = u256 { high: 0, low: spent_amount } * safe_u16_to_u128(order.price).into();
                                let (net_amount, maker_fee) = _apply_fee(@self, FeeType::Maker(()), quote_amount);

                                quote_spent += quote_amount;

                                _transfer_quote_token(ref self, order_owner, net_amount);
                                // IDistributorDispatcher { contract_address: self.distributor.read() }.new_distribution(self.quote_token.read(), maker_fee);
                                _distribute_fees(@self, maker_fee);

                                self.emit(Event::Matched(
                                    Matched { maker_order_id: order.order_id, maker: order_owner, 
                                            asset: Asset::Not(()), matched_amount:  u256 { high: 0, low : spent_amount},
                                            price: order.price, taker: taker, taker_side: 0_u8}
                                ));
                            };
                        },
                        Option::None(()) => {
                            let last_orders = orders_modified.clone();
                            let sorted_orders = _sort_orders(true, last_orders);
                            self.not.write(1_u8, sorted_orders);
                            break;
                        }
                    };
                };
                return (amount_left, quote_spent);    
            }
        }
    }

    fn _cancel_buy_order(ref self: ContractState, owner: ContractAddress, asset: Asset, order_id: u32) {
        // gönderilecek miktar price * amount
        match asset {
            Asset::Happens(()) => {
                let mut orders = self.happens.read(0_u8);
                let mut new_orders = ArrayTrait::<felt252>::new();
                loop {
                    match orders.pop_front() {
                        Option::Some(v) => {
                            let unpacked_order: Order = unpack_order(v);

                            if(unpacked_order.order_id != order_id) {
                                new_orders.append(v);
                                continue;
                            }

                            let transfer_amount: u256 = safe_u16_to_u128(unpacked_order.price).into() * unpacked_order.amount.into();

                            _transfer_quote_token(ref self, owner, transfer_amount);
                        },
                        Option::None(()) => {
                            break;
                        }
                    };
                };

                let sorted_orders: Array<felt252> = _sort_orders(false, new_orders);
                self.happens.write(0_u8, sorted_orders);
            },
            Asset::Not(()) => {
                let mut orders = self.not.read(0_u8);
                let mut new_orders = ArrayTrait::<felt252>::new();
                loop {
                    match orders.pop_front() {
                        Option::Some(v) => {
                            let unpacked_order: Order = unpack_order(v);

                            if(unpacked_order.order_id != order_id) {
                                new_orders.append(v);
                                continue;
                            }

                            let transfer_amount: u256 = safe_u16_to_u128(unpacked_order.price).into() * unpacked_order.amount.into();

                            _transfer_quote_token(ref self, owner, transfer_amount);
                        },
                        Option::None(()) => {
                            break;
                        }
                    };
                };

                let sorted_orders: Array<felt252> = _sort_orders(false, new_orders);
                self.not.write(0_u8, sorted_orders);
            }
        };
    }

    fn _cancel_sell_order(ref self: ContractState, owner: ContractAddress, asset: Asset, order_id: u32) {
        match asset {
            Asset::Happens(()) => {
                let mut orders = self.happens.read(1_u8);
                let mut new_orders = ArrayTrait::<felt252>::new();
                loop {
                    match orders.pop_front() {
                        Option::Some(v) => {
                            let unpacked_order: Order = unpack_order(v);

                            if(unpacked_order.order_id != order_id) {
                                new_orders.append(v);
                                continue;
                            };

                            _transfer_assets(ref self, Asset::Happens(()), owner, unpacked_order.amount.into());
                        },
                        Option::None(()) => {
                            break;
                        }
                    };
                };

                let sorted_orders: Array<felt252> = _sort_orders(true, new_orders);
                self.happens.write(1_u8, sorted_orders);
            },
            Asset::Not(()) => {
                let mut orders = self.not.read(1_u8);
                let mut new_orders = ArrayTrait::<felt252>::new();
                loop {
                    match orders.pop_front() {
                        Option::Some(v) => {
                            let unpacked_order: Order = unpack_order(v);

                            if(unpacked_order.order_id != order_id) {
                                new_orders.append(v);
                                continue;
                            };

                            _transfer_assets(ref self, Asset::Not(()), owner, unpacked_order.amount.into());
                        },
                        Option::None(()) => {
                            break;
                        }
                    };
                };

                let sorted_orders: Array<felt252> = _sort_orders(true, new_orders);
                self.not.write(1_u8, sorted_orders);
            }
        }
    }

    fn _find_order(self: @ContractState, asset: Asset, side: u8, order_id: u32) -> felt252 {
        match asset {
            Asset::Happens(()) => {
                let mut orders = self.happens.read(side);
                if(orders.len() == 0) {
                    return 0;
                }
                let mut found_order: felt252 = 0;
                loop {
                    match orders.pop_front() {
                        Option::Some(v) => {
                            let order = unpack_order(v);
                            if(order.order_id == order_id) {
                                found_order = v;
                                break;
                            };
                        },
                        Option::None(()) => {
                            break;
                        }
                    };
                };
                return found_order;
            },
            Asset::Not(()) => {
                let mut orders = self.not.read(side);
                if(orders.len() == 0) {
                    return 0;
                }
                let mut found_order: felt252 = 0;
                loop {
                    match orders.pop_front() {
                        Option::Some(v) => {
                            let order = unpack_order(v);
                            if(order.order_id == order_id) {
                                found_order = v;
                                break;
                            };
                        },
                        Option::None(()) => {
                            break;
                        }
                    };
                };
                return found_order;
            }
        }
    }

    fn _sort_orders(ascending: bool, orders: Array<felt252>) -> Array<felt252> {
        if(ascending) {
            _sort_orders_ascending(orders)
        } else {
            _sort_orders_descending(orders)
        }
    }

    fn _distribute_fees(self: @ContractState, amount: u256) {
        if(amount > 0) {
            IDistributorDispatcher { contract_address: self.distributor.read() }.new_distribution(self.quote_token.read(), amount);
        }
    }

    fn _receive_quote_token(ref self: ContractState, from: ContractAddress, amount: u256) {
        let this_addr = get_contract_address();
        let quote = self.quote_token.read();

        let balanceBefore = IERC20Dispatcher { contract_address: quote}.balanceOf(this_addr);

        IERC20Dispatcher { contract_address: quote }.transferFrom(from, this_addr, amount);

        let balanceAfter = IERC20Dispatcher { contract_address: quote }.balanceOf(this_addr);
        assert((balanceAfter - amount) >= balanceBefore, 'EXPM: transfer fail')
    }

    fn _transfer_quote_token(ref self: ContractState, to: ContractAddress, amount: u256) {
        IERC20Dispatcher { contract_address: self.quote_token.read() }.transfer(to, amount);
    }

    fn _transfer_assets(ref self: ContractState, asset: Asset, to: ContractAddress, amount: u256) {
        let market = self.market.read();
        let this_addr = get_contract_address();

        let balance = IMarketDispatcher { contract_address: market }.balance_of(this_addr, asset);
        assert(balance >= amount, 'EXPO: balance exceeds');

        IMarketDispatcher { contract_address: market }.transfer(to, asset, amount);
    }

    fn _receive_assets(ref self: ContractState, asset: Asset, from: ContractAddress, amount: u256) {
        let this_addr = get_contract_address();
        let market = self.market.read();

        let balance_before = IMarketDispatcher { contract_address: market }.balance_of(this_addr, asset);
        IMarketDispatcher { contract_address: market }.transfer_from(from, this_addr, asset, amount);
        let balance_after = IMarketDispatcher { contract_address: market }.balance_of(this_addr, asset);

        assert((balance_after - amount) >= balance_before, 'EXPO: transfer fail')
    }

    fn _is_emergency(self: @ContractState) -> bool {
        self.is_emergency.read()
    }

    // returns (fee_deducted, fee_mount)
    fn _apply_fee(self: @ContractState, fee_type: FeeType, amount: u256) -> (u256, u256) {
        let fees: PlatformFees = self.fees.read();

        match fee_type {
            FeeType::Maker(()) => {
                let fee_amount: u256 = (amount * safe_u32_to_u128(fees.maker).into()) / 10000;
                let fee_deducted: u256 = amount - fee_amount;

                assert((fee_deducted + fee_amount) <= amount, 'fee wrong');

                return (fee_deducted, fee_amount);
            },
            FeeType::Taker(()) => {
                let fee_amount: u256 = (amount * safe_u32_to_u128(fees.taker).into()) / 10000;
                let fee_deducted: u256 = amount - fee_amount;

                assert((fee_deducted + fee_amount) <= amount, 'fee wrong');

                return (fee_deducted, fee_amount);
            }
        }
    }
}