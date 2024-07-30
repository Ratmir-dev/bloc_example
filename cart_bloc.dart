import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_insider/flutter_insider.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:fres_mobile/model/model.dart';
import 'package:fres_mobile/modules/cart/cubit/checkout_info_cubit.dart';
import 'package:fres_mobile/modules/cart/cubit/promo_code_cubit.dart';
import 'package:fres_mobile/modules/order/ongoing_order/bloc/ongoing_order_bloc.dart';
import 'package:fres_mobile/services/services.dart';
import 'package:fres_mobile/view_models/location_view_model.dart';
import 'package:fres_mobile/view_models/missing_item_view_model.dart';

part 'cart_bloc.freezed.dart';

@freezed
class CartEvent with _$CartEvent {
  const CartEvent._();
  const factory CartEvent.added({required Product product, String? subCategoryId, String? categoryId, String? storyId, String? source}) = ProductAddedCartEvent;
  const factory CartEvent.restoredFromCache() = RestoredFromCacheCartEvent;
  const factory CartEvent.countDecreased({required Product product}) = ProductCountDecreasedCartEvent;
  const factory CartEvent.adjusted({required List<MissingItemViewModel> missingItems}) = AdjustedCartEvent;
  const factory CartEvent.cleared({required bool isCloseCartScreen}) = ClearedCartEvent;
}

@freezed
class CartState with _$CartState {
  const factory CartState({required LinkedHashMap<String?, ProductWrapper> items, @Default(true) bool isCloseCartScreen}) = _CartState;
  factory CartState.initial() => CartState(items: LinkedHashMap<String?, ProductWrapper>.from({}), isCloseCartScreen: false);
}

class CartBloc extends Bloc<CartEvent, CartState> {
  CartBloc({required this.checkoutInfoCubit, required LocationViewModel userLocationViewModel, required this.ongoingOrderBloc, required this.promoCodeCubit})
      : _userLocationViewModel = userLocationViewModel,
        super(CartState.initial()) {
    on<CartEvent>(
      (event, emit) async => await event.when(
        added: (Product product, String? subCategoryId, String? categoryId, String? storyId, String? source) =>
            _mapAddedToState(emit, product, subCategoryId, categoryId, storyId, source),
        restoredFromCache: () => _mapRestoredCartToState(emit),
        countDecreased: (Product product) => _mapCountDecreasedToState(emit, product),
        adjusted: (List<MissingItemViewModel> missingItems) => _mapAdjustedToState(emit, missingItems),
        cleared: (bool isCloseCartScreen) => _mapClearedToState(emit, isCloseCartScreen),
      ),
    );
    _userLocationViewModel.addCustomListener(deliveryLocationListener);
  }

  final LocationViewModel _userLocationViewModel;
  final OngoingOrdersBloc ongoingOrderBloc;
  final CheckoutInfoCubit checkoutInfoCubit;
  final PromoCodeCubit promoCodeCubit;

  @override
  Future<void> close() async {
    super.close();
    _userLocationViewModel.removeCustomListener(deliveryLocationListener);
  }

  @override
  void onTransition(Transition<CartEvent, CartState> transition) {
    super.onTransition(transition);
    final items = transition.nextState.items;

    checkoutInfoCubit.updateCheckoutInfo(items.values.toList());

    PersistanceService().saveCartItems(items, _userLocationViewModel.currentFresLocationInfo!.areas[0].name);
  }

  Future<void> _mapAddedToState(Emitter emit, Product product, String? subCategoryId, String? categoryId, String? storyId, String? source) async {
    FirebaseEventService.instance.logEvent(name: 'add_to_cart_click', parameters: {});
    if (state.items.isEmpty) FirebaseEventService.instance.logEvent(name: 'cart_created', parameters: {});

    final items = _changeProductCount(product, 1, subCategoryId: subCategoryId, categoryId: categoryId, storyId: storyId, source: source);

    emit(state.copyWith(items: items));

    final productWithCount = state.items[product.productId];
    if (productWithCount != null) {
      AppsflyerService.instance.logAddToCart(productWithCount);
      FirebaseEventService.instance.logCardManipulationEvent(name: 'add_to_cart', productWithCount: productWithCount, subCategoryId: subCategoryId);
      FlutterInsider.Instance.itemAddedToCart(productWithCount.toInsiderProduct);
    }
  }

  Future<void> _mapCountDecreasedToState(Emitter emit, Product product) async {
    final unacceptedProductsHashMap = _changeProductCount(product, -1);
    emit(state.copyWith(items: unacceptedProductsHashMap, isCloseCartScreen: true));

    final productWithCount = state.items.containsKey(product.productId) ? state.items[product.productId]! : ProductWrapper(product: product, count: 0);
    FirebaseEventService.instance.logCardManipulationEvent(name: 'remove_from_cart', productWithCount: productWithCount);
    FlutterInsider.Instance.itemRemovedFromCart(product.productId!);
  }

  Future<void> _mapAdjustedToState(Emitter emit, List<MissingItemViewModel> missingItems) async {
    final items = state.items;
    for (final item in missingItems) {
      items[item.product!.product.productId]!.count = item.inStock ?? 0;
      if (item.inStock == 0) {
        items.remove(item.product!.product.productId);
      }
    }

    emit(state.copyWith(items: items));
  }

  Future<void> _mapClearedToState(Emitter emit, bool isCloseCartScreen) async {
    final items = LinkedHashMap<String?, ProductWrapper>.from({});
    promoCodeCubit.cancel();
    FlutterInsider.Instance.cartCleared();
    emit(state.copyWith(items: items, isCloseCartScreen: isCloseCartScreen));
  }

  Future<void> _mapRestoredCartToState(Emitter emit) async {
    final cacheItems = await PersistanceService().getCartItems(_userLocationViewModel.currentFresLocationInfo!.areas[0].name);
    if (cacheItems.isEmpty) return;

    final cartItems = cacheItems.values
        .map(
          (e) => CartItem(
            productId: e.product.productId,
            quantity: e.count,
            source: e.source,
            storyId: e.fromStoryId,
            subcategoryId: e.fromSubcategoryId,
            categoryId: e.fromCategoryId,
          ),
        )
        .toList();

    try {
      final missingItems = await FresClient.instance.checkStocks(cartItems) ?? [];

      for (final item in missingItems) {
        if (item.availableQuantity == 0) {
          cacheItems.remove(item.productId);
        } else {
          cacheItems[item.productId]!.count = item.availableQuantity!;
        }
      }
    } catch (e) {}

    emit(state.copyWith(items: cacheItems));
  }

  void deliveryLocationListener(FresLocationInfo fresLocationInfo, GisLocationModel gisLocationModel) {
    if (fresLocationInfo.areas[0].name == LocationType.express &&
        _userLocationViewModel.currentFresLocationInfo?.areas[0].name == LocationType.express &&
        fresLocationInfo.locationId != _userLocationViewModel.currentFresLocationInfo?.locationId) {
      add(const CartEvent.cleared(isCloseCartScreen: true));
    }
  }

  LinkedHashMap<String?, ProductWrapper> _changeProductCount(
    Product product,
    int value, {
    String? subCategoryId,
    String? categoryId,
    String? storyId,
    String? source,
  }) =>
      LinkedHashMap<String?, ProductWrapper>.from(state.items)
        ..update(
          product.productId,
          (productWrapper) => ProductWrapper(
            product: productWrapper.product,
            count: math.min(productWrapper.count + value, productWrapper.product.inStock),
            source: productWrapper.source,
            fromSubcategoryId: productWrapper.fromSubcategoryId,
            fromCategoryId: productWrapper.fromCategoryId,
            fromStoryId: productWrapper.fromStoryId,
          ),
          ifAbsent: () => ProductWrapper(
            product: product,
            count: 1,
            source: source,
            fromSubcategoryId: subCategoryId,
            fromCategoryId: categoryId,
            fromStoryId: storyId,
          ),
        )
        ..removeWhere((key, value) => value.count == 0);
}

class OrderTooSmallError implements Exception {}
